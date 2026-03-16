defmodule ExAutoresearch.Agent.Referee do
  @moduledoc """
  Monitors concurrent training trials and kills losing ones early.

  Subscribes to PubSub step events. When multiple trials are in-flight,
  compares their loss at common step checkpoints. A trial is killed if:

  1. Both trials have reached the comparison checkpoint (50% of step_budget)
  2. One trial's loss is >20% worse than the other at the same step count
  3. OR a trial's loss is rising (last 1000 steps trending upward)

  Killing frees the GPU to start the next experiment immediately.
  """

  use GenServer

  require Logger

  alias ExAutoresearch.Experiments.Runner

  defstruct [:step_budget, trials: %{}, killed: MapSet.new()]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    step_budget = Keyword.fetch!(opts, :step_budget)
    Phoenix.PubSub.subscribe(ExAutoresearch.PubSub, "agent:events")
    {:ok, %__MODULE__{step_budget: step_budget}}
  end

  @impl true
  def handle_info({:trial_started, %{version_id: vid}}, state) do
    {:noreply, %{state | trials: Map.put(state.trials, vid, %{points: []})}}
  end

  @impl true
  def handle_info({:trial_completed, %{version_id: vid}}, state) do
    {:noreply, %{state |
      trials: Map.delete(state.trials, vid),
      killed: MapSet.delete(state.killed, vid)
    }}
  end

  @impl true
  def handle_info({:step, %{version_id: vid, step: step, loss: loss}}, state) when is_number(loss) do
    # Ignore events from already-killed trials
    if MapSet.member?(state.killed, vid) do
      {:noreply, state}
    else
      state = update_in(state.trials[vid], fn
        nil -> %{points: [{step, loss}]}
        trial -> %{trial | points: [{step, loss} | Enum.take(trial.points, 99)]}
      end)

      active = state.trials |> Enum.filter(fn {_, t} -> length(t.points) > 0 end)

      state =
        if length(active) >= 2 do
          maybe_kill_loser(state, active)
        else
          state
        end

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  # Compare trials at their most recent common step range.
  # Kill the loser. If the winner is on a slower GPU, halt it too and
  # queue a migration to the faster (now-freed) GPU.
  defp maybe_kill_loser(state, active) do
    checkpoint = div(state.step_budget, 2)

    # Only act when all trials are past the checkpoint
    all_past_checkpoint? = Enum.all?(active, fn {_, t} ->
      {latest_step, _} = hd(t.points)
      latest_step >= checkpoint
    end)

    if all_past_checkpoint? do
      with_loss =
        Enum.map(active, fn {vid, t} ->
          {_step, loss} = Enum.min_by(t.points, fn {s, _} -> abs(s - checkpoint) end)
          {latest_step, _} = hd(t.points)
          {vid, loss, loss_trending_up?(t.points), latest_step}
        end)

      {best_vid, best_loss, _, _} = Enum.min_by(with_loss, fn {_, loss, _, _} -> loss end)
      {worst_vid, worst_loss, _, _} = Enum.max_by(with_loss, fn {_, loss, _, _} -> loss end)

      if best_vid != worst_vid do
        ratio = worst_loss / best_loss
        {_, _, trending_up?, _} = Enum.find(with_loss, fn {vid, _, _, _} -> vid == worst_vid end)

        should_kill? = ratio > 1.2 or trending_up?

        if should_kill? do
          reason = if trending_up?, do: "loss trending upward", else: "#{Float.round((ratio - 1) * 100, 1)}% worse"
          Logger.info("🏁 Referee: halting v_#{worst_vid} (#{reason} vs v_#{best_vid})")
          kill_trial(worst_vid)

          # Only kill the loser — let the winner finish on its GPU.
          # The loser's GPU is freed immediately for a new experiment.
          %{state |
            trials: Map.delete(state.trials, worst_vid),
            killed: MapSet.put(state.killed, worst_vid)
          }
        else
          state
        end
      else
        state
      end
    else
      state
    end
  end

  # Check if loss is trending upward over the last ~20 recorded points
  defp loss_trending_up?(points) when length(points) < 10, do: false

  defp loss_trending_up?(points) do
    recent = Enum.take(points, 10)
    {_, newest_loss} = hd(recent)
    {_, oldest_loss} = List.last(recent)
    # Loss is rising if newest > oldest by >5%
    newest_loss > oldest_loss * 1.05
  end

  defp kill_trial(version_id) do
    # Signal local halt
    Runner.halt(version_id)

    # Also signal on all connected nodes (for remote trials)
    for node <- Node.list() do
      :rpc.cast(node, Runner, :halt, [version_id])
    end
  end
end
