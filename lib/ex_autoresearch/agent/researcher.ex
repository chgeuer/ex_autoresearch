defmodule ExAutoresearch.Agent.Researcher do
  @moduledoc """
  Autonomous experiment loop with full persistence.

  All state lives in SQLite via Ash. Stops and resumes are seamless —
  the agent picks up where it left off by loading experiment history.
  Model can be switched mid-flight via set_model/1.

  When multiple GPU nodes are available (e.g. ROCm + CUDA), spawns one
  independent loop per node. Each loop proposes its own experiment via
  the LLM, trains on its assigned GPU, and writes results to the shared
  SQLite database. When either loop finds a new best, the other picks
  it up on its next iteration automatically.
  """

  use GenServer

  require Logger

  alias ExAutoresearch.Experiments.{Registry, Loader, Runner}
  alias ExAutoresearch.Agent.{LLM, Prompts}
  alias ExAutoresearch.Agent.LLM.CopilotBackend

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
                             doc: "Starting seconds per trial (min when adaptive)"
                           ],
                           max_time_budget: [
                             type: {:or, [:pos_integer, {:in, [nil]}]},
                             default: 300,
                             doc: "Max seconds per trial. Set nil to disable adaptive scaling."
                           ],
                           step_budget: [
                             type: {:or, [:pos_integer, {:in, [nil]}]},
                             default: nil,
                             doc: "Fixed step count per trial. When set, overrides time-based budgets for fair cross-GPU comparison."
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
    case Registry.active_campaign() do
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
        kept_count = length(Registry.kept_trials(run.id))

        %{
          status: run.status,
          campaign_tag: run.tag,
          trial_count: Registry.count_trials(run.id),
          best_loss: best && best.final_loss,
          best_version: best && best.version_id,
          model: run.model,
          time_budget: effective_time_budget(run, kept_count)
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
    case Registry.active_campaign() do
      {:ok, nil} -> []
      {:ok, run} -> Registry.all_trials(run.id)
    end
  rescue
    _ -> []
  end

  # Server

  @impl true
  def init(_opts) do
    # Reset any stale :running campaigns left over from a previous app session
    case Registry.active_campaign() do
      {:ok, run} when not is_nil(run) ->
        Logger.info("Resetting stale running campaign #{run.tag} to paused")
        Registry.pause_campaign(run)
        broadcast(:status_changed, %{status: :paused})

      _ ->
        :ok
    end

    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:start_research, opts}, state) do
    tag = opts[:tag]
    model = opts[:model]
    time_budget = opts[:time_budget]
    max_time_budget = opts[:max_time_budget]
    step_budget = opts[:step_budget]

    # Resume existing run or create new one
    run =
      case Registry.get_campaign(tag) do
        {:ok, nil} ->
          Logger.info("Creating new run: #{tag}")

          Registry.start_campaign(tag,
            model: model,
            time_budget: time_budget,
            max_time_budget: max_time_budget,
            step_budget: step_budget
          )

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
      case Registry.get_campaign_by_id(state.campaign_id) do
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
      case Registry.get_campaign_by_id(state.campaign_id) do
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

  @max_consecutive_errors 5

  defp experiment_loop(run) do
    nodes = gpu_nodes()

    # Run baseline if no experiments yet — prefer the fastest GPU (workers first)
    if Registry.count_trials(run.id) == 0 do
      {baseline_label, baseline_node} = List.last(nodes)
      Logger.info("[#{run.tag}] Running baseline on #{baseline_label}...")
      run_baseline(run, baseline_label, baseline_node)
    end

    Logger.info("[#{run.tag}] Starting #{length(nodes)} parallel GPU loop(s): #{inspect(Enum.map(nodes, &elem(&1, 0)))}")

    # Start the referee that monitors concurrent trials and kills losers
    referee = if run.step_budget && length(nodes) > 1 do
      {:ok, pid} = ExAutoresearch.Agent.Referee.start_link(step_budget: run.step_budget)
      pid
    end

    # Spawn one independent loop per GPU node
    tasks =
      nodes
      |> Enum.map(fn {label, target_node} ->
        Task.async(fn -> gpu_loop(run, label, target_node) end)
      end)

    # Wait for all loops to finish (they run until campaign is paused/stopped)
    Task.await_many(tasks, :infinity)

    if referee, do: GenServer.stop(referee, :normal)
  end

  # Returns [{label, node_atom}] for each available GPU.
  # Local node is always included. Connected worker nodes are added.
  defp gpu_nodes do
    local_target = System.get_env("GPU_TARGET", "rocm")
    local = {"local/#{local_target}", node()}

    workers =
      Node.list()
      |> Enum.filter(fn n ->
        name = Atom.to_string(n)
        String.contains?(name, "worker") or String.contains?(name, "cuda")
      end)
      |> Enum.map(fn n ->
        # Try to detect the GPU target on the remote node
        gpu = try do
          :rpc.call(n, System, :get_env, ["GPU_TARGET"], 5_000)
        catch
          _, _ -> "unknown"
        end
        gpu = gpu || "unknown"
        {"#{Atom.to_string(n)}/#{gpu}", n}
      end)

    [local | workers]
  end

  # Independent loop for one GPU node. Each loop has its own Copilot
  # session so LLM calls run in parallel across GPU loops.
  defp gpu_loop(run, label, target_node, consecutive_errors \\ 0, llm_pid \\ nil) do
    # Start a dedicated Copilot backend for this loop (once)
    llm_pid =
      if llm_pid && Process.alive?(llm_pid) do
        llm_pid
      else
        Logger.info("[#{label}] Starting dedicated Copilot session")
        {:ok, pid} = CopilotBackend.start_link(model: run.model)
        # Give it time to connect
        Process.sleep(2_000)
        pid
      end

    run = Ash.get!(ExAutoresearch.Research.Campaign, run.id)

    if run.status == :running do
      case propose_and_run(run, label, target_node, llm_pid) do
        :ok ->
          gpu_loop(run, label, target_node, 0, llm_pid)

        {:error, reason} ->
          errors = consecutive_errors + 1
          Logger.error("[#{label}] Failed (#{errors}/#{@max_consecutive_errors}): #{inspect(reason, limit: 3)}")
          broadcast(:experiment_error, %{error: inspect(reason, limit: 3), attempt: errors, max: @max_consecutive_errors})

          if errors >= @max_consecutive_errors do
            Logger.error("[#{label}] Too many consecutive errors, stopping this GPU loop")
          else
            backoff = min(3_000 * errors, 15_000)
            Process.sleep(backoff)
            gpu_loop(run, label, target_node, errors, llm_pid)
          end
      end
    else
      Logger.info("[#{label}] GPU loop stopped")
      if llm_pid, do: GenServer.stop(llm_pid, :normal)
    end
  end

  defp run_baseline(run, label, target_node) do
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

        broadcast(:trial_started, %{version_id: version_id, description: "baseline", gpu: label})

        result = run_on_node(target_node, module, code, version_id, effective_time_budget(run, 0), run.step_budget)

        experiment =
          Registry.complete_trial(experiment, %{
            final_loss: result[:loss],
            num_steps: result[:steps],
            training_seconds: result[:training_seconds],
            status: if(result[:loss], do: :completed, else: :crashed),
            kept: result[:loss] != nil,
            loss_history: Jason.encode!(result[:loss_history] || [])
          })

        if result[:loss], do: Registry.update_campaign_best(run, experiment.id)

        broadcast(
          :trial_completed,
          Map.merge(result, %{
            description: "baseline",
            kept: result[:loss] != nil,
            model: run.model,
            gpu: label
          })
        )

      {:error, reason} ->
        Logger.error("Baseline failed to load: #{inspect(reason)}")
    end
  end

  defp propose_and_run(run, label, target_node, llm_pid) do
    version_id = gen_id()
    all_exps = Registry.all_trials(run.id)
    best = Registry.best_trial(run.id)
    kept = Registry.kept_trials(run.id)
    effective_budget = effective_time_budget(run, length(kept))

    # Build prompt with full context
    prompt = Prompts.build_proposal_prompt(all_exps, best, kept, version_id)
    full_prompt = "#{Prompts.system_prompt()}\n\n---\n\n#{prompt}"

    Logger.info("[#{label}] Asking #{run.model} for experiment v_#{version_id}...")
    broadcast(:agent_thinking, %{version_id: version_id})

    case GenServer.call(llm_pid, {:prompt, full_prompt, run.model}, :timer.minutes(5)) do
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

            broadcast(:trial_started, %{version_id: version_id, description: description, gpu: label})

            result = run_on_node(target_node, module, code, version_id, effective_budget, run.step_budget)

            loss = sanitize_loss(result[:loss])
            halted? = result[:status] == :halted
            kept = if halted?, do: false, else: decide_keep(loss, best && best.final_loss)

            trial_status =
              cond do
                halted? -> :discarded
                loss -> :completed
                true -> :crashed
              end

            experiment =
              Registry.complete_trial(experiment, %{
                final_loss: loss,
                num_steps: result[:steps],
                training_seconds: result[:training_seconds],
                status: trial_status,
                kept: kept,
                loss_history: Jason.encode!(result[:loss_history] || [])
              })

            if kept, do: Registry.update_campaign_best(run, experiment.id)

            broadcast(
              :trial_completed,
              Map.merge(result, %{
                description: description,
                kept: kept,
                model: run.model,
                gpu: label
              })
            )

            :ok

          {:error, reason} ->
            Logger.error("[#{label}] Module v_#{version_id} failed to load: #{inspect(reason)}")

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
              gpu: label,
              error: inspect(reason)
            })

            :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Execute training on the target node. Local node runs directly,
  # remote nodes get the code shipped via :rpc.call and compile+train there.
  defp run_on_node(target_node, module, _code, version_id, time_budget, step_budget) when target_node == node() do
    Runner.run(module, version_id: version_id, time_budget: time_budget, step_budget: step_budget)
  end

  defp run_on_node(target_node, _module, code, version_id, time_budget, step_budget) do
    Logger.info("[#{version_id}] Dispatching to remote node #{target_node}")

    # Ship source code to the remote node: compile + train there
    case :rpc.call(target_node, Code, :compile_string, [code], 30_000) do
      modules when is_list(modules) ->
        {remote_module, _bytecode} = List.last(modules)

        case :rpc.call(target_node, Runner, :run, [remote_module, [version_id: version_id, time_budget: time_budget, step_budget: step_budget]], :infinity) do
          {:badrpc, reason} ->
            Logger.error("[#{version_id}] Remote training failed: #{inspect(reason, limit: 3)}")
            %{version_id: version_id, status: :crashed, loss: nil, steps: 0, training_seconds: 0, error: inspect(reason), loss_history: []}

          result when is_map(result) ->
            result
        end

      {:badrpc, reason} ->
        Logger.error("[#{version_id}] Remote compile failed: #{inspect(reason, limit: 3)}")
        %{version_id: version_id, status: :crashed, loss: nil, steps: 0, training_seconds: 0, error: inspect(reason), loss_history: []}
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

  # Adaptive time budget: starts at time_budget, doubles per kept trial, caps at max_time_budget.
  # When step_budget is set, time budget is just a safety timeout (24h).
  # When max_time_budget is nil, uses time_budget as fixed value.
  defp effective_time_budget(run, kept_count) do
    if run.step_budget do
      # Step-based mode: time is not the limiting factor
      86_400
    else
      case run.max_time_budget do
        nil ->
          run.time_budget

        max when is_integer(max) ->
          budget = run.time_budget * Integer.pow(2, kept_count)
          min(budget, max)
      end
    end
  end

  defp safe_round(val, d) when is_float(val), do: Float.round(val, d)
  defp safe_round(val, _d), do: val

  # NaN, Inf, and atoms like :nan are not valid float values for SQLite
  defp sanitize_loss(nil), do: nil
  defp sanitize_loss(:nan), do: nil
  defp sanitize_loss(:infinity), do: nil
  defp sanitize_loss(:neg_infinity), do: nil

  defp sanitize_loss(v) when is_float(v) do
    cond do
      v != v -> nil
      abs(v) > 1.0e30 -> nil
      true -> v
    end
  end

  defp sanitize_loss(_), do: nil

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(ExAutoresearch.PubSub, "agent:events", {event, payload})
  rescue
    _ -> :ok
  end

  defp gen_id, do: :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)
end
