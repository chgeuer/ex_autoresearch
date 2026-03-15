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

  defstruct [:step_budget, trials: %{}]

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
    {:noreply, %{state | trials: Map.delete(state.trials, vid)}}
  end

  @impl true
  def handle_info({:step, %{version_id: vid, step: step, loss: loss}}, state) when is_number(loss) do
    state = update_in(state.trials[vid], fn
      nil -> %{points: [{step, loss}]}
      trial -> %{trial | points: [{step, loss} | Enum.take(trial.points, 99)]}
    end)

    # Only compare when we have 2+ in-flight trials past the halfway checkpoint
    active = state.trials |> Enum.filter(fn {_, t} -> length(t.points) > 0 end)

    state =
      if length(active) >= 2 do
        maybe_kill_loser(state, active)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  # Compare trials at their most recent common step range.
  # Kill the one that's clearly worse (>20% higher loss at same step count).
  defp maybe_kill_loser(state, active) do
    checkpoint = div(state.step_budget, 2)

    # Only act when all trials are past the checkpoint
    all_past_checkpoint? = Enum.all?(active, fn {_, t} ->
      {latest_step, _} = hd(t.points)
      latest_step >= checkpoint
    end)

    if all_past_checkpoint? do
      # Get loss at the checkpoint for each trial (closest point)
      with_loss =
        Enum.map(active, fn {vid, t} ->
          {_step, loss} = Enum.min_by(t.points, fn {s, _} -> abs(s - checkpoint) end)
          {vid, loss, loss_trending_up?(t.points)}
        end)

      {best_vid, best_loss, _} = Enum.min_by(with_loss, fn {_, loss, _} -> loss end)

      Enum.reduce(with_loss, state, fn {vid, loss, trending_up?}, acc ->
        if vid != best_vid do
          ratio = loss / best_loss

          cond do
            # >20% worse at checkpoint
            ratio > 1.2 ->
              Logger.info("🏁 Referee: killing v_#{vid} (loss #{Float.round(loss, 6)} is #{Float.round((ratio - 1) * 100, 1)}% worse than v_#{best_vid})")
              kill_trial(vid)
              %{acc | trials: Map.delete(acc.trials, vid)}

            # Loss is rising — unstable training
            trending_up? ->
              Logger.info("🏁 Referee: killing v_#{vid} (loss trending upward)")
              kill_trial(vid)
              %{acc | trials: Map.delete(acc.trials, vid)}

            true ->
              acc
          end
        else
          acc
        end
      end)
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
