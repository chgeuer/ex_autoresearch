defmodule ExAutoresearch.Training.Trainer do
  @moduledoc """
  Time-budgeted training GenServer.

  Manages the full training loop:
  1. Build model and optimizer from config
  2. Run forward/backward passes with gradient accumulation
  3. Apply LR schedule based on wall-clock progress
  4. Stop after time_budget seconds
  5. Report results via PubSub
  """

  use GenServer

  require Logger

  alias ExAutoresearch.Model.{Config, GPT}
  alias ExAutoresearch.Training.Scheduler
  alias ExAutoresearch.Data.Loader

  defstruct [
    :config,
    :experiment_id,
    status: :idle,
    result: nil
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a training run with the given config.

  Returns `{:ok, result}` when training completes, where result contains
  the final loss, step count, and timing information.
  """
  def train(%Config{} = config, opts \\ []) do
    GenServer.call(__MODULE__, {:train, config, opts}, :infinity)
  end

  @doc "Get current training status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:train, config, opts}, _from, _state) do
    experiment_id = Keyword.get(opts, :experiment_id, generate_id())

    new_state = %__MODULE__{
      config: config,
      experiment_id: experiment_id,
      status: :training
    }

    broadcast("training:#{experiment_id}", :started, %{
      config: config,
      experiment_id: experiment_id
    })

    result = run_training(config, experiment_id)

    final_state = %{new_state | status: :completed, result: result}

    broadcast("training:#{experiment_id}", :complete, result)

    {:reply, {:ok, result}, final_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, experiment_id: state.experiment_id, result: state.result}, state}
  end

  # Training implementation

  defp run_training(%Config{} = config, experiment_id) do
    n_embd = Config.n_embd(config)
    Logger.info("[#{experiment_id}] Training: #{config.n_layer}L × #{n_embd}d, vocab=#{config.vocab_size}")

    # Build model
    model = GPT.build(config)
    {init_fn, _predict_fn} = Axon.build(model)

    # Initialize params
    template = %{"input_ids" => Nx.iota({config.device_batch_size, config.sequence_len}, type: :s64)}
    _params = init_fn.(template, Axon.ModelState.empty())

    # Setup optimizer
    optimizer = Polaris.Optimizers.adamw(
      learning_rate: config.matrix_lr,
      b1: config.adam_beta1,
      b2: config.adam_beta2,
      decay: config.weight_decay
    )

    # Setup loss function
    loss_fn = fn y_pred, y_true ->
      Axon.Losses.categorical_cross_entropy(y_pred, y_true, from_logits: true, reduction: :mean)
    end

    # Create data stream
    data = Loader.stream(config)

    # Clear process dictionary from previous runs
    Process.delete(:training_start_time)
    Process.delete(:training_steps)
    Process.delete(:last_loss)

    time_budget_ms = config.time_budget * 1000

    # Custom handler to stop after time budget (excluding JIT warmup)
    halt_handler = fn state ->
      # Start timer after first iteration (JIT warmup done)
      unless Process.get(:training_start_time) do
        Process.put(:training_start_time, System.monotonic_time(:millisecond))
        Process.put(:training_steps, 0)
        Logger.info("[#{experiment_id}] JIT warmup done, starting #{config.time_budget}s timer")
      end

      Process.put(:training_steps, (Process.get(:training_steps) || 0) + 1)

      # Track the raw loss from metrics (running mean)
      case state.metrics do
        %{"loss" => %Nx.Tensor{} = loss} ->
          val = Nx.to_number(loss)
          # Skip the initial 0.0 from Axon's running mean
          if val > 0.0, do: Process.put(:last_loss, val)
        _ -> :ok
      end

      start = Process.get(:training_start_time)
      elapsed = System.monotonic_time(:millisecond) - start

      if elapsed >= time_budget_ms do
        {:halt_loop, state}
      else
        {:continue, state}
      end
    end

    # Custom handler to broadcast progress
    log_handler = fn state ->
      step = state.iteration
      start = Process.get(:training_start_time) || System.monotonic_time(:millisecond)
      elapsed = System.monotonic_time(:millisecond) - start
      progress = min(elapsed / time_budget_ms, 1.0)

      if rem(step, 5) == 0 do
        loss_val = case state.metrics do
          %{"loss" => loss} -> Nx.to_number(loss)
          _ -> nil
        end

        lr_mult = Scheduler.lr_multiplier(progress, config)

        broadcast("training:#{experiment_id}", :step, %{
          step: step,
          loss: loss_val,
          lr_multiplier: lr_mult,
          progress: Float.round(progress * 100, 1),
          elapsed_ms: elapsed
        })
      end

      {:continue, state}
    end

    loop =
      Axon.Loop.trainer(model, loss_fn, optimizer, log: 1)
      |> Axon.Loop.handle_event(:iteration_completed, log_handler)
      |> Axon.Loop.handle_event(:iteration_completed, halt_handler)

    Logger.info("[#{experiment_id}] Starting training (JIT warmup first, then #{config.time_budget}s)")

    # Run training — use a large iteration count; halt_handler stops us on time
    final_state = Axon.Loop.run(loop, data, %{}, epochs: 1, iterations: 100_000)

    training_start = Process.get(:training_start_time) || System.monotonic_time(:millisecond)
    elapsed_ms = System.monotonic_time(:millisecond) - training_start
    elapsed_s = elapsed_ms / 1000

    # Extract final metrics — prefer Axon state, fall back to process dict
    final_step = Process.get(:training_steps, 0)

    final_loss =
      case final_state do
        %Axon.Loop.State{metrics: %{"loss" => %Nx.Tensor{} = t}} ->
          val = Nx.to_number(t)
          if val > 0.0, do: val, else: Process.get(:last_loss)

        _ ->
          Process.get(:last_loss)
      end

    result = %{
      experiment_id: experiment_id,
      status: :completed,
      training_seconds: Float.round(elapsed_s, 1),
      num_steps: final_step,
      final_loss: final_loss,
      n_layer: config.n_layer,
      n_embd: n_embd,
      vocab_size: config.vocab_size,
      sequence_len: config.sequence_len
    }

    Logger.info("[#{experiment_id}] Training complete: #{result.num_steps} steps in #{result.training_seconds}s")

    result
  end

  defp broadcast(topic, event, payload) do
    Phoenix.PubSub.broadcast(ExAutoresearch.PubSub, topic, {event, payload})
  rescue
    _ -> :ok
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
