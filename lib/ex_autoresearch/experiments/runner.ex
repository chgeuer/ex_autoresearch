defmodule ExAutoresearch.Experiments.Runner do
  @moduledoc """
  Runs a training experiment against a loaded experiment module.

  Takes a module that implements build/0, config/0, optimizer/0,
  trains it for the time budget, and returns results.
  """

  require Logger

  alias ExAutoresearch.Data.Loader, as: DataLoader

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
    do_run(module, version_id, time_budget, step_budget)
  end

  defp do_run(module, version_id, time_budget, step_budget) do
    config = module.config()
    vocab_size = config[:vocab_size] || 256
    seq_len = config[:sequence_len] || config[:seq_len] || 32
    batch_size = config[:batch_size] || config[:device_batch_size] || 4

    Logger.info("[#{version_id}] Training: #{inspect(config, limit: 5)}")

    model = module.build()
    {opt_init, _opt_update} = optimizer = module.optimizer()

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

    time_budget_ms = time_budget * 1000

    budget_label =
      if step_budget, do: "#{step_budget} steps (max #{time_budget}s)", else: "#{time_budget}s"

    halt_handler = fn state ->
      unless Process.get(:training_start_time) do
        Process.put(:training_start_time, System.monotonic_time(:millisecond))
        Process.put(:training_steps, 0)
        Logger.info("[#{version_id}] JIT warmup done, starting training: #{budget_label}")
      end

      steps = (Process.get(:training_steps) || 0) + 1
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
          true -> false
        end

      if halt?, do: {:halt_loop, state}, else: {:continue, state}
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

    Logger.info("[#{version_id}] Starting training (JIT warmup, then #{budget_label})")

    _final = Axon.Loop.run(loop, data, %{}, epochs: 1, iterations: 1_000_000)

    training_start = Process.get(:training_start_time) || System.monotonic_time(:millisecond)
    elapsed_s = (System.monotonic_time(:millisecond) - training_start) / 1000

    steps = Process.get(:training_steps, 0)
    loss = Process.get(:last_loss)

    Logger.info(
      "[#{version_id}] Done: #{steps} steps in #{safe_round(elapsed_s, 1)}s, loss=#{loss && safe_round(loss, 6)}"
    )

    %{
      version_id: version_id,
      status: :completed,
      loss: loss,
      steps: steps,
      training_seconds: safe_round(elapsed_s, 1),
      config: config,
      loss_history: Process.get(:loss_history, []) |> Enum.reverse() |> downsample(200)
    }
  rescue
    e ->
      Logger.error("[#{version_id}] Training crashed: #{Exception.message(e)}")

      %{
        version_id: version_id,
        status: :crashed,
        loss: nil,
        steps: 0,
        training_seconds: 0,
        error: Exception.message(e),
        loss_history: []
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
