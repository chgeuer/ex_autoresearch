defmodule ExAutoresearch.Experiments.Runner do
  @moduledoc """
  Runs a training experiment against a loaded experiment module.

  Takes a module that implements build/0, config/0, optimizer/0,
  trains it for the time budget, and returns results.

  Supports:
  - External early-stop signals via `halt/1`
  - Checkpoint serialization when halted for GPU migration
  - Resuming from a serialized checkpoint via `resume/3`
  """

  require Logger

  alias ExAutoresearch.Data.Loader, as: DataLoader

  @halt_table __MODULE__.HaltSignals
  @checkpoint_table __MODULE__.Checkpoints

  def init_tables do
    if :ets.whereis(@halt_table) == :undefined do
      :ets.new(@halt_table, [:named_table, :set, :public, write_concurrency: true])
    end

    if :ets.whereis(@checkpoint_table) == :undefined do
      :ets.new(@checkpoint_table, [:named_table, :set, :public])
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Signal a running trial to stop early."
  def halt(version_id) do
    init_tables()
    :ets.insert(@halt_table, {version_id, true})
    Logger.info("[#{version_id}] Halt signal sent")
  end

  @doc "Retrieve a serialized checkpoint for a halted trial."
  def get_checkpoint(version_id) do
    case :ets.whereis(@checkpoint_table) do
      :undefined -> nil
      _ ->
        case :ets.lookup(@checkpoint_table, version_id) do
          [{_, checkpoint}] ->
            :ets.delete(@checkpoint_table, version_id)
            checkpoint
          _ -> nil
        end
    end
  end

  defp halted?(version_id) do
    case :ets.whereis(@halt_table) do
      :undefined -> false
      _ ->
        case :ets.lookup(@halt_table, version_id) do
          [{_, true}] -> true
          _ -> false
        end
    end
  end

  defp clear_halt(version_id) do
    if :ets.whereis(@halt_table) != :undefined do
      :ets.delete(@halt_table, version_id)
    end
  end

  @default_time_budget to_timeout(minute: 5) |> div(1000)

  @run_schema NimbleOptions.new!(
                time_budget: [type: :pos_integer, default: @default_time_budget, doc: "Max seconds (safety timeout)"],
                step_budget: [type: {:or, [:pos_integer, {:in, [nil]}]}, default: nil, doc: "Stop after this many steps (nil = use time_budget)"],
                version_id: [
                  type: :string,
                  default: "unknown",
                  doc: "Experiment version identifier"
                ]
              )

  @doc """
  Train an experiment module and return results.

  The module must implement:
  - config/0 → map with at least :vocab_size, :sequence_len, :batch_size
  - build/0 → Axon model
  - optimizer/0 → Polaris optimizer
  - loss_fn/2 (optional) → custom loss function

  ## Options

  #{NimbleOptions.docs(@run_schema)}
  """
  @spec run(module(), keyword()) :: map()
  def run(module, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @run_schema)
    time_budget = opts[:time_budget]
    step_budget = opts[:step_budget]
    version_id = opts[:version_id]
    init_tables()
    clear_halt(version_id)
    do_run(module, version_id, time_budget, step_budget, nil)
  end

  @doc """
  Resume training from a serialized checkpoint.

  The checkpoint contains the full Axon.Loop.State (model params +
  optimizer state). Training continues from where it left off,
  running for `remaining_steps` more steps.
  """
  @spec resume(module(), binary(), keyword()) :: map()
  def resume(module, checkpoint_binary, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @run_schema)
    time_budget = opts[:time_budget]
    step_budget = opts[:step_budget]
    version_id = opts[:version_id]
    init_tables()
    clear_halt(version_id)

    prev_state = Axon.Loop.deserialize_state(checkpoint_binary)
    completed_steps = prev_state.iteration
    Logger.info("[#{version_id}] Resuming from checkpoint at step #{completed_steps}")

    do_run(module, version_id, time_budget, step_budget, prev_state)
  end

  defp do_run(module, version_id, time_budget, step_budget, prev_state) do
    config = module.config()
    vocab_size = config[:vocab_size] || 256
    seq_len = config[:sequence_len] || config[:seq_len] || 32
    batch_size = config[:batch_size] || config[:device_batch_size] || 4

    completed_steps = if prev_state, do: prev_state.iteration, else: 0
    Logger.info("[#{version_id}] Training: #{inspect(config, limit: 5)}#{if completed_steps > 0, do: " (resuming from step #{completed_steps})"}")

    model = module.build()
    {_opt_init, _opt_update} = optimizer = module.optimizer()

    loss_fn =
      if function_exported?(module, :loss_fn, 2) do
        &module.loss_fn/2
      else
        fn y_pred, y_true ->
          Axon.Losses.categorical_cross_entropy(y_pred, y_true,
            from_logits: true,
            reduction: :mean
          )
        end
      end

    # Data stream
    data = DataLoader.synthetic_stream(batch_size, seq_len, vocab_size)

    # Clear process dict from prior runs
    Process.delete(:training_start_time)
    Process.delete(:training_steps)
    Process.delete(:last_loss)
    Process.delete(:loss_history)
    Process.delete(:final_loop_state)

    time_budget_ms = time_budget * 1000

    budget_label =
      if step_budget, do: "#{step_budget} steps (max #{time_budget}s)", else: "#{time_budget}s"

    halt_handler = fn state ->
      unless Process.get(:training_start_time) do
        Process.put(:training_start_time, System.monotonic_time(:millisecond))
        Process.put(:training_steps, completed_steps)
        Logger.info("[#{version_id}] JIT warmup done, starting training: #{budget_label}")
      end

      steps = (Process.get(:training_steps) || completed_steps) + 1
      Process.put(:training_steps, steps)

      case state.metrics do
        %{"loss" => %Nx.Tensor{} = loss} ->
          val = Nx.to_number(loss)
          if val > 0.0, do: Process.put(:last_loss, val)

        _ ->
          :ok
      end

      start = Process.get(:training_start_time)
      elapsed = System.monotonic_time(:millisecond) - start

      halt? =
        cond do
          step_budget && steps >= step_budget -> true
          elapsed >= time_budget_ms -> true
          rem(steps, 500) == 0 and halted?(version_id) -> true
          true -> false
        end

      if halt?, do: {:halt_epoch, state}, else: {:continue, state}
    end

    progress_handler = fn state ->
      try do
        step = Process.get(:training_steps, 0)

        if rem(step, 50) == 0 do
          loss = Process.get(:last_loss)

          if loss do
            history = Process.get(:loss_history, [])
            Process.put(:loss_history, [[step, loss] | history])
          end
          if loss, do: Logger.debug("[#{version_id}] step=#{step} loss=#{safe_round(loss, 6)}")

          Phoenix.PubSub.broadcast(
            ExAutoresearch.PubSub,
            "agent:events",
            {:step,
             %{
               version_id: version_id,
               step: step,
               loss: loss,
               progress: training_progress(time_budget_ms, step_budget)
             }}
          )
        end
      rescue
        _ -> :ok
      end

      {:continue, state}
    end

    loop =
      Axon.Loop.trainer(model, loss_fn, optimizer, log: 0)
      |> Axon.Loop.handle_event(:iteration_completed, progress_handler)
      |> Axon.Loop.handle_event(:iteration_completed, halt_handler)

    # Capture full loop state on the last iteration for checkpoint/migration.
    # We can't use output_transform (it's used by metrics), so we stash it
    # in the process dictionary from the halt_handler's final call.
    loop =
      if step_budget do
        Axon.Loop.handle_event(loop, :epoch_halted, fn state ->
          Process.put(:final_loop_state, state)
          {:continue, state}
        end)
      else
        loop
      end

    # Attach previous state for resume
    loop = if prev_state, do: Axon.Loop.from_state(loop, prev_state), else: loop

    remaining = if step_budget, do: step_budget - completed_steps, else: 1_000_000

    Logger.info("[#{version_id}] Starting training (JIT warmup, then #{budget_label})")

    _final = Axon.Loop.run(loop, data, %{}, epochs: 1, iterations: remaining)

    training_start = Process.get(:training_start_time) || System.monotonic_time(:millisecond)
    elapsed_s = (System.monotonic_time(:millisecond) - training_start) / 1000

    steps = Process.get(:training_steps, 0) + completed_steps
    loss = Process.get(:last_loss)
    was_halted = halted?(version_id)
    clear_halt(version_id)

    status = if was_halted, do: :halted, else: :completed

    # Serialize checkpoint for GPU migration when halted early
    if was_halted and step_budget do
      case Process.get(:final_loop_state) do
        %Axon.Loop.State{} = loop_state ->
          try do
            checkpoint = Axon.Loop.serialize_state(loop_state)
            :ets.insert(@checkpoint_table, {version_id, checkpoint})
            Logger.info("[#{version_id}] Checkpoint saved (#{div(byte_size(checkpoint), 1024)} KB)")
          rescue
            e ->
              Logger.warning("[#{version_id}] Checkpoint serialization failed: #{Exception.message(e)}")
          end

        _ ->
          Logger.warning("[#{version_id}] No loop state captured for checkpoint")
      end
      Process.delete(:final_loop_state)
    end

    Logger.info(
      "[#{version_id}] Done: #{steps} steps in #{safe_round(elapsed_s, 1)}s, loss=#{loss && safe_round(loss, 6)}#{if was_halted, do: " (halted by referee)"}"
    )

    %{
      version_id: version_id,
      status: status,
      loss: loss,
      steps: steps,
      training_seconds: safe_round(elapsed_s, 1),
      config: config,
      loss_history: Process.get(:loss_history, []) |> Enum.reverse() |> downsample(200)
    }
  rescue
    e ->
      stacktrace = __STACKTRACE__ |> Exception.format_stacktrace() |> String.slice(0, 2000)
      error_detail = "#{Exception.message(e)}\n#{stacktrace}"
      steps = Process.get(:training_steps, 0)
      elapsed = case Process.get(:training_start_time) do
        nil -> 0.0
        start -> (System.monotonic_time(:millisecond) - start) / 1000
      end
      loss = Process.get(:last_loss)
      crash_phase = cond do
        steps == 0 and String.contains?(stacktrace, "Axon.Loop") -> :jit_compile
        steps == 0 -> :model_build
        steps > 0 and loss == nil -> :early_training
        steps > 0 -> :mid_training
        true -> :unknown
      end

      Logger.error("[#{version_id}] Training crashed in #{crash_phase} phase (step #{steps}): #{error_detail}")

      %{
        version_id: version_id,
        status: :crashed,
        loss: loss,
        steps: steps,
        training_seconds: safe_round(elapsed, 1),
        error: "[#{crash_phase}] #{error_detail}",
        loss_history: Process.get(:loss_history, []) |> Enum.reverse() |> downsample(200)
      }
  end

  defp training_progress(time_budget_ms, step_budget) do
    steps = Process.get(:training_steps, 0)

    if step_budget do
      safe_round(min(steps / step_budget, 1.0) * 100, 1)
    else
      case Process.get(:training_start_time) do
        nil ->
          0.0

        start ->
          elapsed = System.monotonic_time(:millisecond) - start
          safe_round(min(elapsed / time_budget_ms, 1.0) * 100, 1)
      end
    end
  end

  defp safe_round(val, decimals) when is_float(val), do: Float.round(val, decimals)
  defp safe_round(val, _decimals) when is_integer(val), do: val / 1
  defp safe_round(_, _), do: nil

  # Keep at most max_points evenly spaced samples from a list of [step, loss] pairs.
  defp downsample(points, max_points) when length(points) <= max_points, do: points

  defp downsample(points, max_points) do
    n = length(points)
    step = n / max_points

    0..(max_points - 1)
    |> Enum.map(fn i -> Enum.at(points, round(i * step)) end)
    |> Enum.reject(&is_nil/1)
  end
end
