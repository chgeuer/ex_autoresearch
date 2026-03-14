defmodule ExAutoresearch.Agent.Researcher do
  @moduledoc """
  Autonomous experiment loop with full persistence.

  All state lives in SQLite via Ash. Stops and resumes are seamless —
  the agent picks up where it left off by loading experiment history.
  Model can be switched mid-flight via set_model/1.
  """

  use GenServer

  require Logger

  alias ExAutoresearch.Experiments.{Registry, Loader, Runner}
  alias ExAutoresearch.Agent.{LLM, Prompts}

  defstruct [:campaign_id, :task, status: :idle]

  @start_research_schema NimbleOptions.new!(
                           tag: [type: :string, required: true, doc: "Campaign tag"],
                           model: [
                             type: :string,
                             default: "claude-sonnet-4",
                             doc: "LLM model to use"
                           ],
                           time_budget: [
                             type: :pos_integer,
                             default: 15,
                             doc: "Seconds per trial"
                           ]
                         )

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start or resume a research run with the given tag.

  ## Options

  #{NimbleOptions.docs(@start_research_schema)}
  """
  @spec start_research(keyword()) :: :ok
  def start_research(opts \\ []) do
    opts = NimbleOptions.validate!(opts, @start_research_schema)
    GenServer.cast(__MODULE__, {:start_research, opts})
  end

  @doc "Stop the experiment loop after current experiment finishes."
  @spec stop_research() :: :ok
  def stop_research do
    GenServer.cast(__MODULE__, :stop_research)
  end

  @doc "Switch the LLM model mid-flight. Takes effect on the next experiment."
  @spec set_model(String.t()) :: :ok
  def set_model(model_id) when is_binary(model_id) and model_id != "" do
    GenServer.cast(__MODULE__, {:set_model, model_id})
  end

  @doc "Get current status (reads from SQLite, never blocks)."
  def status do
    case Registry.active_run() do
      {:ok, nil} ->
        %{
          status: :idle,
          trial_count: 0,
          best_loss: nil,
          best_version: nil,
          model: "claude-sonnet-4",
          campaign_tag: nil
        }

      {:ok, run} ->
        best = Registry.best_trial(run.id)

        %{
          status: run.status,
          campaign_tag: run.tag,
          trial_count: Registry.count_trials(run.id),
          best_loss: best && best.final_loss,
          best_version: best && best.version_id,
          model: run.model
        }
    end
  rescue
    _ ->
      %{
        status: :idle,
        trial_count: 0,
        best_loss: nil,
        best_version: nil,
        model: "claude-sonnet-4",
        campaign_tag: nil
      }
  end

  @doc "Get all experiments for the active run."
  def experiments do
    case Registry.active_run() do
      {:ok, nil} -> []
      {:ok, run} -> Registry.all_trials(run.id)
    end
  rescue
    _ -> []
  end

  # Server

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:start_research, opts}, state) do
    tag = opts[:tag]
    model = opts[:model]
    time_budget = opts[:time_budget]

    # Resume existing run or create new one
    run =
      case Registry.get_campaign(tag) do
        {:ok, nil} ->
          Logger.info("Creating new run: #{tag}")
          Registry.start_campaign(tag, model: model, time_budget: time_budget)

        {:ok, existing} ->
          Logger.info("Resuming run: #{tag} (#{Registry.count_trials(existing.id)} experiments)")
          Registry.resume_campaign(existing)
      end

    broadcast(:status_changed, %{status: :running})

    task = Task.async(fn -> experiment_loop(run) end)
    {:noreply, %{state | campaign_id: run.id, task: task, status: :running}}
  end

  @impl true
  def handle_cast(:stop_research, state) do
    Logger.info("Stop requested — will stop after current experiment")

    if state.campaign_id do
      case Registry.get_run_by_id(state.campaign_id) do
        {:ok, run} when not is_nil(run) -> Registry.pause_campaign(run)
        _ -> :ok
      end
    end

    {:noreply, %{state | status: :stopping}}
  end

  @impl true
  def handle_cast({:set_model, model_id}, state) do
    Logger.info("Switching model to: #{model_id}")

    if state.campaign_id do
      case Registry.get_run_by_id(state.campaign_id) do
        {:ok, run} when not is_nil(run) -> Registry.update_campaign_model(run, model_id)
        _ -> :ok
      end
    end

    broadcast(:status_changed, %{status: state.status, model: model_id})
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    broadcast(:status_changed, %{status: :idle})
    {:noreply, %{state | task: nil, status: :idle}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("Experiment loop crashed: #{inspect(reason, limit: 3)}")
    broadcast(:status_changed, %{status: :idle})
    {:noreply, %{state | task: nil, status: :idle}}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  # --- Experiment loop ---

  defp experiment_loop(run) do
    # Run baseline if no experiments yet
    if Registry.count_trials(run.id) == 0 do
      Logger.info("[#{run.tag}] Running baseline...")
      run_baseline(run)
    end

    loop(run)
  end

  defp loop(run) do
    # Re-read run from DB to get latest status/model (may have been changed mid-flight)
    run = Ash.get!(ExAutoresearch.Research.Campaign, run.id)

    if run.status == :running do
      case propose_and_run(run) do
        :ok ->
          loop(run)

        {:error, reason} ->
          Logger.error("Experiment failed: #{inspect(reason, limit: 3)}")
          Process.sleep(3_000)
          loop(run)
      end
    else
      Logger.info("[#{run.tag}] Research loop stopped")
    end
  end

  defp run_baseline(run) do
    version_id = gen_id()
    template = Prompts.read("template.md")

    code =
      case Regex.run(~r/```elixir\n(.*?)```/s, template) do
        [_, c] -> c
        _ -> template
      end

    code = Loader.inject_version_id(code, version_id)

    case Loader.load(version_id, code) do
      {:ok, module} ->
        Registry.cache_module(version_id, module)

        experiment =
          Registry.record_trial(%{
            campaign_id: run.id,
            version_id: version_id,
            code: code,
            description: "baseline",
            model: run.model,
            status: :running
          })

        broadcast(:trial_started, %{version_id: version_id, description: "baseline"})

        result = Runner.run(module, version_id: version_id, time_budget: run.time_budget)

        experiment =
          Registry.complete_trial(experiment, %{
            final_loss: result[:loss],
            num_steps: result[:steps],
            training_seconds: result[:training_seconds],
            status: if(result[:loss], do: :completed, else: :crashed),
            kept: result[:loss] != nil
          })

        if result[:loss], do: Registry.update_campaign_best(run, experiment.id)

        broadcast(
          :trial_completed,
          Map.merge(result, %{
            description: "baseline",
            kept: result[:loss] != nil,
            model: run.model
          })
        )

      {:error, reason} ->
        Logger.error("Baseline failed to load: #{inspect(reason)}")
    end
  end

  defp propose_and_run(run) do
    version_id = gen_id()
    all_exps = Registry.all_trials(run.id)
    best = Registry.best_trial(run.id)
    kept = Registry.kept_trials(run.id)

    # Build prompt with full context
    prompt = Prompts.build_proposal_prompt(all_exps, best, kept, version_id)

    Logger.info("[#{run.tag}] Asking #{run.model} for experiment v_#{version_id}...")
    broadcast(:agent_thinking, %{version_id: version_id})

    case LLM.prompt(prompt, system: Prompts.system_prompt(), model: run.model) do
      {:ok, response} ->
        {code, description, reasoning} = parse_response(response, version_id)
        broadcast(:agent_responded, %{reasoning: reasoning, description: description})

        code = Loader.inject_version_id(code, version_id)

        case Loader.load(version_id, code) do
          {:ok, module} ->
            Registry.cache_module(version_id, module)

            experiment =
              Registry.record_trial(%{
                campaign_id: run.id,
                version_id: version_id,
                code: code,
                description: description,
                reasoning: reasoning,
                parent_id: best && best.id,
                model: run.model,
                status: :running
              })

            broadcast(:trial_started, %{version_id: version_id, description: description})

            result = Runner.run(module, version_id: version_id, time_budget: run.time_budget)

            loss = sanitize_loss(result[:loss])
            kept = decide_keep(loss, best && best.final_loss)

            experiment =
              Registry.complete_trial(experiment, %{
                final_loss: loss,
                num_steps: result[:steps],
                training_seconds: result[:training_seconds],
                status: if(loss, do: :completed, else: :crashed),
                kept: kept
              })

            if kept, do: Registry.update_campaign_best(run, experiment.id)

            broadcast(
              :trial_completed,
              Map.merge(result, %{
                description: description,
                kept: kept,
                model: run.model
              })
            )

            :ok

          {:error, reason} ->
            Logger.error("Module v_#{version_id} failed to load: #{inspect(reason)}")

            Registry.record_trial(%{
              campaign_id: run.id,
              version_id: version_id,
              code: code,
              description: description,
              reasoning: reasoning,
              parent_id: best && best.id,
              model: run.model,
              status: :crashed,
              error: inspect(reason)
            })

            broadcast(:trial_completed, %{
              version_id: version_id,
              description: description,
              kept: false,
              status: :crashed,
              loss: nil,
              steps: 0,
              model: run.model,
              error: inspect(reason)
            })

            :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(response, version_id) do
    code =
      case Regex.run(~r/```elixir\n(.*?)```/s, response) do
        [_, c] -> c
        _ -> response
      end

    reasoning =
      case Regex.run(~r/"reasoning"\s*:\s*"([^"]+)"/s, response) do
        [_, r] ->
          r

        _ ->
          case Regex.run(~r/@moduledoc\s+"([^"]+)"/s, code) do
            [_, d] -> d
            _ -> String.slice(response, 0, 200)
          end
      end

    description =
      case Regex.run(~r/@moduledoc\s+"([^"]+)"/s, code) do
        [_, d] -> String.slice(d, 0, 300)
        _ -> "LLM experiment v_#{version_id}"
      end

    {code, description, reasoning}
  end

  defp decide_keep(nil, _baseline), do: false
  defp decide_keep(_loss, nil), do: true

  defp decide_keep(loss, baseline) when loss < baseline do
    Logger.info("✅ Improvement! #{safe_round(baseline, 6)} → #{safe_round(loss, 6)}")
    true
  end

  defp decide_keep(loss, baseline) do
    Logger.info("❌ No improvement: #{safe_round(loss, 6)} >= #{safe_round(baseline, 6)}")
    false
  end

  defp safe_round(val, d) when is_float(val), do: Float.round(val, d)
  defp safe_round(val, _d), do: val

  # NaN, Inf, and atoms like :nan are not valid float values for SQLite
  defp sanitize_loss(nil), do: nil
  defp sanitize_loss(:nan), do: nil
  defp sanitize_loss(:infinity), do: nil
  defp sanitize_loss(:neg_infinity), do: nil

  defp sanitize_loss(v) when is_float(v) do
    if v != v or v == :math.exp(800), do: nil, else: v
  end

  defp sanitize_loss(_), do: nil

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(ExAutoresearch.PubSub, "agent:events", {event, payload})
  rescue
    _ -> :ok
  end

  defp gen_id, do: :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)
end
