defmodule ExAutoresearch.Agent.Researcher do
  @moduledoc """
  Autonomous experiment loop.

  Uses ETS for status so reads never block, even during training.
  The experiment loop runs in a separate Task.
  """

  use GenServer

  require Logger

  alias ExAutoresearch.Model.Config
  alias ExAutoresearch.Training.Trainer
  alias ExAutoresearch.Agent.{LLM, Program}

  @status_table __MODULE__.Status

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start the autonomous experiment loop."
  def start_research(opts \\ []) do
    GenServer.cast(__MODULE__, {:start_research, opts})
  end

  @doc "Stop after current experiment finishes."
  def stop_research do
    put_status(:status, :stopping)
  end

  @doc "Get current status (reads ETS, never blocks)."
  def status do
    %{
      status: get_status(:status, :idle),
      experiment_count: get_status(:experiment_count, 0),
      baseline_loss: get_status(:baseline_loss, nil),
      current_config: get_status(:current_config, default_config()),
      current_step: get_status(:current_step, nil),
      current_progress: get_status(:current_progress, nil)
    }
  end

  @doc "Get experiment history (reads ETS, never blocks)."
  def experiments do
    get_status(:experiments, [])
  end

  # Server

  @impl true
  def init(opts) do
    :ets.new(@status_table, [:named_table, :set, :public, read_concurrency: true])

    config = Keyword.get(opts, :config, default_config())
    put_status(:status, :idle)
    put_status(:current_config, config)
    put_status(:experiments, [])
    put_status(:experiment_count, 0)
    put_status(:baseline_loss, nil)
    put_status(:model, Keyword.get(opts, :model, "claude-sonnet-4"))

    {:ok, %{task: nil}}
  end

  @impl true
  def handle_cast({:start_research, opts}, state) do
    config = Keyword.get(opts, :config, get_status(:current_config, default_config()))
    put_status(:current_config, config)
    put_status(:status, :running)

    if opts[:model], do: put_status(:model, opts[:model])

    broadcast(:status_changed, %{status: :running})

    task = Task.async(fn -> experiment_loop() end)
    {:noreply, %{state | task: task}}
  end

  @impl true
  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    put_status(:status, :idle)
    broadcast(:status_changed, %{status: :idle})
    {:noreply, %{state | task: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("Experiment loop crashed: #{inspect(reason)}")
    put_status(:status, :idle)
    broadcast(:status_changed, %{status: :idle})
    {:noreply, %{state | task: nil}}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  # Experiment loop (runs in a Task, uses ETS for state)

  defp experiment_loop do
    # Ensure Trainer is running
    case GenServer.whereis(Trainer) do
      nil -> Trainer.start_link()
      _pid -> :ok
    end

    # Run baseline if no experiments yet
    if get_status(:experiment_count, 0) == 0 do
      Logger.info("Running baseline experiment...")
      config = get_status(:current_config, default_config())
      run_experiment(config, "baseline")
    end

    loop()
  end

  defp loop do
    if get_status(:status) == :running do
      case propose_next_experiment() do
        {:ok, config, description} ->
          run_experiment(config, description)
          loop()

        {:error, reason} ->
          Logger.error("Proposal failed: #{inspect(reason)}")
          Process.sleep(5_000)
          loop()
      end
    else
      Logger.info("Research loop stopped")
    end
  end

  defp run_experiment(config, description) do
    experiment_id = generate_id()
    Logger.info("[#{experiment_id}] Running: #{description}")

    broadcast(:experiment_started, %{
      experiment_id: experiment_id,
      description: description
    })

    put_status(:current_step, 0)
    put_status(:current_progress, 0)

    result =
      case Trainer.train(config, experiment_id: experiment_id) do
        {:ok, train_result} ->
          Map.merge(train_result, %{description: description})

        {:error, reason} ->
          %{
            experiment_id: experiment_id,
            status: :crashed,
            description: description,
            error: inspect(reason),
            final_loss: nil,
            num_steps: 0,
            training_seconds: 0
          }
      end

    # Decide keep/discard
    baseline = get_status(:baseline_loss)
    {kept, new_baseline} = decide(result[:final_loss], baseline)
    full_result = Map.merge(result, %{kept: kept, id: get_status(:experiment_count, 0)})

    # Update ETS state
    exps = get_status(:experiments, [])
    put_status(:experiments, exps ++ [full_result])
    put_status(:experiment_count, length(exps) + 1)
    put_status(:baseline_loss, new_baseline)
    put_status(:current_step, nil)
    put_status(:current_progress, nil)

    if kept, do: put_status(:current_config, config)

    broadcast(:experiment_completed, full_result)

    full_result
  end

  defp propose_next_experiment do
    config = get_status(:current_config, default_config())
    experiments = get_status(:experiments, [])

    prompt_text = Program.format_proposal_request(experiments, config)

    Logger.info("Asking LLM for next experiment...")
    broadcast(:agent_thinking, %{prompt: String.slice(prompt_text, 0, 200) <> "..."})

    case LLM.prompt(prompt_text, system: Program.system_prompt(), model: get_status(:model, "claude-sonnet-4")) do
      {:ok, response} ->
        Logger.info("LLM responded (#{String.length(response)} chars)")
        broadcast(:agent_responded, %{response: response})
        parse_proposal(response, config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_proposal(response, current_config) do
    json_str =
      case Regex.run(~r/```(?:json)?\s*\n(.*?)\n```/s, response) do
        [_, json] -> json
        _ -> response
      end

    case Jason.decode(json_str) do
      {:ok, %{"changes" => changes, "description" => desc}} ->
        {:ok, apply_changes(current_config, changes), desc}

      {:ok, %{"changes" => changes}} ->
        {:ok, apply_changes(current_config, changes), "LLM experiment"}

      {:error, _} ->
        Logger.warning("Could not parse LLM JSON, using baseline config")
        {:ok, current_config, "retry (parse error)"}
    end
  end

  defp apply_changes(config, changes) when is_map(changes) do
    Enum.reduce(changes, config, fn {key, value}, acc ->
      atom_key = String.to_existing_atom(key)
      if Map.has_key?(acc, atom_key), do: Map.put(acc, atom_key, value), else: acc
    end)
  rescue
    _ -> config
  end

  defp decide(nil, baseline), do: {false, baseline}
  defp decide(loss, nil) do
    Logger.info("Baseline established: loss=#{loss}")
    {true, loss}
  end
  defp decide(loss, baseline) when loss < baseline do
    Logger.info("✅ Improvement! #{baseline} → #{loss} (Δ#{Float.round(baseline - loss, 6)})")
    {true, loss}
  end
  defp decide(loss, baseline) do
    Logger.info("❌ No improvement: #{loss} >= #{baseline}")
    {false, baseline}
  end

  defp default_config do
    %Config{
      n_layer: 2, aspect_ratio: 16, n_head: 2, n_kv_head: 2, head_dim: 16,
      vocab_size: 256, sequence_len: 32, device_batch_size: 4,
      time_budget: 15, matrix_lr: 0.01
    }
  end

  # ETS helpers

  defp put_status(key, value), do: :ets.insert(@status_table, {key, value})

  defp get_status(key, default \\ nil) do
    case :ets.lookup(@status_table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(ExAutoresearch.PubSub, "agent:events", {event, payload})
  rescue
    _ -> :ok
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
