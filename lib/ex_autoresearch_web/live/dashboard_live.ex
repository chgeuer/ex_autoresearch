defmodule ExAutoresearchWeb.DashboardLive do
  use ExAutoresearchWeb, :live_view

  alias ExAutoresearch.Agent.Researcher

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ExAutoresearch.PubSub, "agent:events")
      Phoenix.PubSub.subscribe(ExAutoresearch.PubSub, "training:*")
      :timer.send_interval(2000, self(), :tick)
    end

    agent_status = Researcher.status()
    experiments = Researcher.experiments()

    socket =
      socket
      |> assign(:agent_status, agent_status.status)
      |> assign(:baseline_loss, agent_status.baseline_loss)
      |> assign(:experiment_count, agent_status.experiment_count)
      |> assign(:current_step, nil)
      |> assign(:current_loss, nil)
      |> assign(:current_progress, nil)
      |> assign(:agent_log, [])
      |> stream(:experiments, experiments |> Enum.with_index() |> Enum.map(fn {e, i} -> Map.put(e, :id, i) end))

    {:ok, socket}
  end

  @impl true
  def handle_event("start_research", _params, socket) do
    Researcher.start_research()
    {:noreply, assign(socket, :agent_status, :running)}
  end

  @impl true
  def handle_event("stop_research", _params, socket) do
    Researcher.stop_research()
    {:noreply, assign(socket, :agent_status, :stopping)}
  end

  @impl true
  def handle_info(:tick, socket) do
    status = Researcher.status()

    socket =
      socket
      |> assign(:agent_status, status.status)
      |> assign(:baseline_loss, status.baseline_loss)
      |> assign(:experiment_count, status.experiment_count)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:experiment_started, payload}, socket) do
    socket =
      socket
      |> assign(:current_step, 0)
      |> assign(:current_loss, nil)
      |> assign(:current_progress, 0)
      |> add_log("🧪 Started: #{payload[:description]}")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:experiment_completed, result}, socket) do
    status = if result[:kept], do: "✅ kept", else: "❌ discarded"
    loss_str = if result[:final_loss], do: Float.round(result[:final_loss], 6), else: "crash"

    socket =
      socket
      |> stream_insert(:experiments, Map.put(result, :id, socket.assigns.experiment_count))
      |> assign(:current_step, nil)
      |> assign(:current_progress, nil)
      |> add_log("#{status} loss=#{loss_str} steps=#{result[:num_steps]} — #{result[:description]}")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:step, payload}, socket) do
    socket =
      socket
      |> assign(:current_step, payload[:step])
      |> assign(:current_loss, payload[:loss])
      |> assign(:current_progress, payload[:progress])

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_thinking, _payload}, socket) do
    {:noreply, add_log(socket, "🤔 Thinking...")}
  end

  @impl true
  def handle_info({:agent_responded, payload}, socket) do
    snippet = String.slice(payload[:response], 0, 120)
    {:noreply, add_log(socket, "💡 #{snippet}...")}
  end

  @impl true
  def handle_info({:status_changed, payload}, socket) do
    {:noreply, assign(socket, :agent_status, payload[:status])}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp add_log(socket, message) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    entry = "#{timestamp} #{message}"
    logs = [entry | socket.assigns.agent_log] |> Enum.take(50)
    assign(socket, :agent_log, logs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto p-6 space-y-6 flex flex-col h-[calc(100vh-6rem)]">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-zinc-100">🔬 ex_autoresearch</h1>
            <p class="text-zinc-400 text-sm">Autonomous GPT training experiments</p>
          </div>
          <div class="flex items-center gap-3">
            <span class={[
              "px-3 py-1 rounded-full text-sm font-medium",
              status_badge_class(@agent_status)
            ]}>
              {@agent_status}
            </span>
            <%= if @agent_status in [:idle, :stopping] do %>
              <button phx-click="start_research"
                class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg text-sm font-medium transition">
                ▶ Start Research
              </button>
            <% else %>
              <button phx-click="stop_research"
                class="px-4 py-2 bg-red-600 hover:bg-red-500 text-white rounded-lg text-sm font-medium transition">
                ⏹ Stop
              </button>
            <% end %>
          </div>
        </div>

        <%!-- Stats bar --%>
        <div class="grid grid-cols-4 gap-4">
          <.stat_card label="Experiments" value={@experiment_count} />
          <.stat_card label="Baseline Loss"
            value={if @baseline_loss, do: Float.round(@baseline_loss, 6), else: "—"} />
          <.stat_card label="Current Step" value={@current_step || "—"} />
          <.stat_card label="Progress"
            value={if @current_progress, do: "#{@current_progress}%", else: "—"} />
        </div>

        <div class="grid grid-cols-2 gap-6 flex-1 min-h-0">
          <%!-- Experiment log --%>
          <div class="bg-zinc-900 rounded-xl border border-zinc-800 p-4 flex flex-col">
            <h2 class="text-lg font-semibold text-zinc-200 mb-3">📊 Experiments</h2>
            <div class="overflow-y-auto flex-1">
              <table class="w-full text-sm">
                <thead>
                  <tr class="text-zinc-500 border-b border-zinc-800">
                    <th class="text-left py-2 px-2">Loss</th>
                    <th class="text-left py-2 px-2">Steps</th>
                    <th class="text-left py-2 px-2">Time</th>
                    <th class="text-left py-2 px-2">Description</th>
                    <th class="text-left py-2 px-2">Status</th>
                  </tr>
                </thead>
                <tbody id="experiments" phx-update="stream">
                  <tr :for={{dom_id, exp} <- @streams.experiments} id={dom_id}
                    class="border-b border-zinc-800/50 hover:bg-zinc-800/30">
                    <td class="py-2 px-2 font-mono text-zinc-300">
                      {format_loss(exp[:final_loss])}
                    </td>
                    <td class="py-2 px-2 text-zinc-400">{exp[:num_steps] || "—"}</td>
                    <td class="py-2 px-2 text-zinc-400">{exp[:training_seconds] && "#{exp[:training_seconds]}s" || "—"}</td>
                    <td class="py-2 px-2 text-zinc-300">{exp[:description] || ""}</td>
                    <td class="py-2 px-2">
                      <span class={if exp[:kept], do: "text-emerald-400", else: "text-red-400"}>
                        {if exp[:kept], do: "✅", else: "❌"}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
              <div class="hidden only:block text-zinc-600 text-center py-8">
                No experiments yet. Hit Start Research to begin.
              </div>
            </div>
          </div>

          <%!-- Agent log --%>
          <div class="bg-zinc-900 rounded-xl border border-zinc-800 p-4 flex flex-col">
            <h2 class="text-lg font-semibold text-zinc-200 mb-3">🤖 Agent Log</h2>
            <div class="overflow-y-auto flex-1 space-y-1">
              <%= if @agent_log == [] do %>
                <p class="text-zinc-600 text-center py-8">Waiting for agent activity...</p>
              <% else %>
                <div :for={entry <- @agent_log}
                  class="text-sm font-mono text-zinc-400 py-0.5">
                  {entry}
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_badge_class(:running), do: "bg-emerald-900 text-emerald-300"
  defp status_badge_class(:stopping), do: "bg-amber-900 text-amber-300"
  defp status_badge_class(_), do: "bg-zinc-800 text-zinc-400"

  defp format_loss(nil), do: "—"
  defp format_loss(loss) when is_float(loss), do: :erlang.float_to_binary(loss, decimals: 6)
  defp format_loss(loss), do: to_string(loss)

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-zinc-900 rounded-xl border border-zinc-800 p-4">
      <div class="text-zinc-500 text-xs uppercase tracking-wider">{@label}</div>
      <div class="text-2xl font-bold text-zinc-100 mt-1">{@value}</div>
    </div>
    """
  end
end
