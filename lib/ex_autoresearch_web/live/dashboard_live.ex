defmodule ExAutoresearchWeb.DashboardLive do
  use ExAutoresearchWeb, :live_view

  alias ExAutoresearch.Agent.Researcher
  alias ExAutoresearch.Experiments.Registry

  @impl true
  def mount(_params, _session, socket) do
    timezone =
      case get_connect_params(socket) do
        %{"timezone" => tz} when is_binary(tz) and tz != "" -> tz
        _ -> "Etc/UTC"
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ExAutoresearch.PubSub, "agent:events")
      :timer.send_interval(2000, self(), :tick)
    end

    agent = Researcher.status()
    campaigns = Registry.list_campaigns()

    # If there's an active campaign, select it; otherwise default to "new"
    {selected_campaign_id, campaign_tag} =
      case agent.campaign_tag && Enum.find(campaigns, &(&1.tag == agent.campaign_tag)) do
        %{id: id, tag: tag} -> {id, tag}
        _ -> {nil, nil}
      end

    trials = load_trials_for(selected_campaign_id)

    selected =
      if agent.best_version, do: load_version(agent.best_version), else: nil

    current_backend = :copilot
    current_model = agent.model || "claude-sonnet-4"
    backend_models = models_for_backend(current_backend)

    socket =
      socket
      |> assign(:timezone, timezone)
      |> assign(:agent_status, agent.status)
      |> assign(:best_loss, agent.best_loss)
      |> assign(:best_version, agent.best_version)
      |> assign(:trial_count, agent.trial_count)
      |> assign(:campaign_tag, campaign_tag)
      |> assign(:campaigns, campaigns)
      |> assign(:selected_campaign_id, selected_campaign_id)
      |> assign(:new_campaign_tag, default_tag())
      |> assign(:time_budget, 300)
      |> assign(:current_step, nil)
      |> assign(:current_progress, nil)
      |> assign(:live_curves, %{})
      |> assign(:agent_log, [])
      |> assign(:selected, selected)
      |> assign(:current_backend, current_backend)
      |> assign(:current_model, current_model)
      |> assign(:backend_models, backend_models)
      |> assign(:chart_trials, trials)
      |> stream(:trials, trials, at: 0)

    socket = push_chart(socket)
    {:ok, push_live_chart(socket)}
  end

  # --- Events ---

  @impl true
  def handle_event("start_research", _params, socket) do
    tag =
      if socket.assigns.selected_campaign_id do
        # Continuing existing campaign
        socket.assigns.campaign_tag
      else
        # New campaign
        tag = String.trim(socket.assigns.new_campaign_tag)
        if tag == "", do: default_tag(), else: tag
      end

    model = socket.assigns.current_model
    backend = socket.assigns.current_backend

    time_budget = socket.assigns.time_budget

    ExAutoresearch.Agent.LLM.set_backend(backend, model)
    Researcher.start_research(tag: tag, model: model, time_budget: time_budget)

    # Refresh campaigns list (new campaign may have been created)
    campaigns = Registry.list_campaigns()
    campaign = Enum.find(campaigns, &(&1.tag == tag))

    {:noreply,
     socket
     |> assign(:agent_status, :running)
     |> assign(:campaign_tag, tag)
     |> assign(:campaigns, campaigns)
     |> assign(:selected_campaign_id, campaign && campaign.id)}
  end

  @impl true
  def handle_event("select_campaign", %{"campaign" => "new"}, socket) do
    {:noreply,
     socket
     |> assign(:selected_campaign_id, nil)
     |> assign(:campaign_tag, nil)
     |> assign(:best_loss, nil)
     |> assign(:best_version, nil)
     |> assign(:trial_count, 0)
     |> assign(:time_budget, 300)
     |> assign(:selected, nil)
     |> assign(:chart_trials, [])
     |> stream(:trials, [], reset: true)
     |> push_chart()}
  end

  @impl true
  def handle_event("select_campaign", %{"campaign" => campaign_id}, socket) do
    campaign = Enum.find(socket.assigns.campaigns, &(&1.id == campaign_id))

    if campaign do
      trials = load_trials_for(campaign.id)
      best = Registry.best_trial(campaign.id)
      trial_count = Registry.count_trials(campaign.id)
      selected = if best, do: load_version(best.version_id), else: nil

      {:noreply,
       socket
       |> assign(:selected_campaign_id, campaign.id)
       |> assign(:campaign_tag, campaign.tag)
       |> assign(:best_loss, best && best.final_loss)
       |> assign(:best_version, best && best.version_id)
       |> assign(:trial_count, trial_count)
       |> assign(:time_budget, campaign.time_budget)
       |> assign(:selected, selected)
       |> assign(:chart_trials, trials)
       |> stream(:trials, trials, reset: true)
       |> push_chart()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_new_tag", %{"tag" => tag}, socket) do
    {:noreply, assign(socket, :new_campaign_tag, tag)}
  end

  @impl true
  def handle_event("change_time_budget", params, socket) do
    case params do
      %{"time_budget" => val} ->
        case Integer.parse(val) do
          {seconds, _} when seconds > 0 ->
            socket = assign(socket, :time_budget, seconds)

            if socket.assigns.selected_campaign_id do
              case Registry.get_campaign_by_id(socket.assigns.selected_campaign_id) do
                {:ok, run} when not is_nil(run) ->
                  Registry.update_campaign_time_budget(run, seconds)

                _ ->
                  :ok
              end
            end

            {:noreply, add_log(socket, "⏱ Time budget → #{seconds}s")}

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop_research", _params, socket) do
    Researcher.stop_research()
    {:noreply, assign(socket, :agent_status, :stopping)}
  end

  @impl true
  def handle_event("select_version", %{"version" => vid}, socket) do
    selected = load_version(vid)
    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def handle_event("select_best", _params, socket) do
    agent = Researcher.status()
    selected = if(agent.best_version, do: load_version(agent.best_version))
    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def handle_event("change_backend", %{"backend" => backend_str}, socket) do
    backend = String.to_existing_atom(backend_str)
    models = models_for_backend(backend)
    default_model = models |> List.first() |> elem(0)

    ExAutoresearch.Agent.LLM.set_backend(backend, default_model)
    Researcher.set_model(default_model)

    {:noreply,
     socket
     |> assign(:current_backend, backend)
     |> assign(:current_model, default_model)
     |> assign(:backend_models, models)
     |> add_log("🔄 Backend -> #{backend}:#{default_model}")}
  end

  @impl true
  def handle_event("change_model", %{"model" => model}, socket) do
    backend = socket.assigns.current_backend
    ExAutoresearch.Agent.LLM.set_backend(backend, model)
    Researcher.set_model(model)

    {:noreply,
     socket
     |> assign(:current_model, model)
     |> add_log("🔄 Model -> #{model}")}
  end

  # --- PubSub ---

  @impl true
  def handle_info(:tick, socket) do
    agent = Researcher.status()
    campaigns = Registry.list_campaigns()

    # Only update stats if viewing the actively running campaign
    socket =
      if agent.campaign_tag && agent.campaign_tag == socket.assigns.campaign_tag do
        socket
        |> assign(:best_loss, agent.best_loss)
        |> assign(:best_version, agent.best_version)
        |> assign(:trial_count, agent.trial_count)
      else
        socket
      end

    {:noreply, assign(socket, :campaigns, campaigns)}
  end

  @impl true
  def handle_info({:trial_started, p}, socket) do
    vid = p[:version_id]
    gpu = p[:gpu] || "local"

    {:noreply,
     socket
     |> assign(:current_step, 0)
     |> assign(:current_progress, 0)
     |> update(:live_curves, &Map.put(&1, vid, []))
     |> push_live_chart()
     |> add_log("🧪 Started: #{p[:description]} (v_#{vid}) on #{gpu}")}
  end

  @impl true
  def handle_info({:trial_completed, r}, socket) do
    tag = if r[:kept], do: "✅ kept", else: "❌ discarded"
    gpu = r[:gpu] || "local"
    entry = trial_to_map(r)

    # Add to chart data, remove from live curves
    chart_trials = [entry | socket.assigns.chart_trials]

    socket =
      socket
      |> stream_insert(:trials, entry, at: 0)
      |> assign(:current_step, nil)
      |> assign(:current_progress, nil)
      |> update(:live_curves, &Map.delete(&1, r[:version_id]))
      |> assign(:chart_trials, chart_trials)
      |> add_log("#{tag} v_#{r[:version_id]} loss=#{safe_fmt(r[:loss])} — #{r[:description]} [#{gpu}]")

    socket =
      if r[:kept], do: assign(socket, :selected, load_version(r[:version_id])), else: socket

    {:noreply, socket |> push_chart() |> push_live_chart()}
  end

  @impl true
  def handle_info({:step, p}, socket) do
    step = p[:step]
    loss = p[:loss]
    vid = p[:version_id]

    socket = socket |> assign(:current_step, step) |> assign(:current_progress, p[:progress])

    if loss && step && vid && rem(step, 50) == 0 do
      live_curves =
        Map.update(socket.assigns.live_curves, vid, [[step, loss]], &(&1 ++ [[step, loss]]))

      {:noreply, socket |> assign(:live_curves, live_curves) |> push_live_chart()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:experiment_error, p}, socket),
    do: {:noreply, add_log(socket, "⚠️ Error (#{p[:attempt]}/#{p[:max]}): #{p[:error]}")}
  @impl true
  def handle_info({:agent_thinking, _}, socket), do: {:noreply, add_log(socket, "🤔 Thinking...")}
  @impl true
  def handle_info({:agent_responded, p}, socket),
    do: {:noreply, add_log(socket, "💡 #{p[:reasoning] || "..."}")}

  @impl true
  def handle_info({:status_changed, p}, socket) do
    socket = assign(socket, :agent_status, p[:status])
    socket = if p[:model], do: assign(socket, :current_model, p[:model]), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp add_log(socket, msg) do
    ts = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    assign(socket, :agent_log, ["#{ts} #{msg}" | socket.assigns.agent_log] |> Enum.take(100))
  end

  defp load_trials_for(nil), do: []

  defp load_trials_for(campaign_id) do
    Registry.all_trials(campaign_id)
    |> Enum.map(&trial_to_map/1)
    |> Enum.reverse()
  end

  defp trial_to_map(%ExAutoresearch.Research.Trial{} = exp) do
    # From Ash struct (SQLite)
    %{
      id: exp.version_id,
      version_id: exp.version_id,
      loss: exp.final_loss,
      steps: exp.num_steps,
      training_seconds: exp.training_seconds,
      description: exp.description,
      kept: exp.kept,
      status: exp.status,
      model: exp.model,
      gpu: nil,
      timestamp: exp.inserted_at
    }
  end

  defp trial_to_map(r) when is_map(r) do
    # From PubSub event (plain map with :loss/:steps keys)
    %{
      id: r[:version_id],
      version_id: r[:version_id],
      loss: r[:loss],
      steps: r[:steps],
      training_seconds: r[:training_seconds],
      description: r[:description],
      kept: r[:kept],
      status: r[:status],
      model: r[:model],
      gpu: r[:gpu],
      timestamp: DateTime.utc_now()
    }
  end

  defp load_version(vid) do
    case Registry.get_trial(vid) do
      {:ok, nil} ->
        nil

      {:ok, exp} ->
        mermaid = build_mermaid(exp)

        %{
          version_id: exp.version_id,
          code: exp.code || "(no source)",
          loss: exp.final_loss,
          steps: exp.num_steps,
          description: exp.description,
          kept: exp.kept,
          status: exp.status,
          model: exp.model,
          mermaid: mermaid,
          loss_history: decode_loss_history(exp.loss_history)
        }

      _ ->
        nil
    end
  end

  defp decode_loss_history(nil), do: []
  defp decode_loss_history(""), do: []

  defp decode_loss_history(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, points} ->
        Enum.filter(points, fn
          [_step, loss] when is_number(loss) -> true
          _ -> false
        end)

      _ ->
        []
    end
  end

  defp decode_loss_history(_), do: []

  defp build_mermaid(exp) do
    if exp.code do
      # Try to compile the module and call build/0 to get the Axon model
      case Registry.get_module(exp.version_id) do
        {:ok, module} ->
          try do
            axon_model = module.build()
            ExAutoresearch.Model.Display.as_mermaid(axon_model)
          rescue
            _ -> nil
          end

        :not_loaded ->
          # Try to reload from stored code
          case Registry.reload_module(exp) do
            {:ok, module} ->
              try do
                axon_model = module.build()
                ExAutoresearch.Model.Display.as_mermaid(axon_model)
              rescue
                _ -> nil
              end

            _ ->
              nil
          end
      end
    end
  rescue
    _ -> nil
  end

  defp push_chart(socket) do
    trials =
      socket.assigns.chart_trials
      |> Enum.reverse()
      |> Enum.filter(& &1[:loss])

    data =
      Enum.with_index(trials)
      |> Enum.map(fn {t, i} ->
        %{
          value: [i, t[:loss]],
          version_id: t[:version_id],
          itemStyle: if(t[:kept], do: %{color: "#34d399"}, else: %{color: "#ef4444"})
        }
      end)

    y_axis = %{
      type: "log",
      name: "Loss",
      nameLocation: "center",
      nameGap: 45,
      axisLabel: %{formatter: "{value}"}
    }

    chart_option = %{
      backgroundColor: "transparent",
      tooltip: %{trigger: "item", formatter: "{c}"},
      xAxis: %{type: "value", name: "Trial #", nameLocation: "center", nameGap: 25, minInterval: 1},
      yAxis: y_axis,
      series: [
        %{
          type: "scatter",
          symbolSize: 8,
          data: data,
          emphasis: %{itemStyle: %{borderColor: "#818cf8", borderWidth: 2}}
        }
      ]
    }

    push_event(socket, "chart-data-loss-chart", chart_option)
  end

  @curve_colors ["#818cf8", "#34d399", "#f472b6", "#fbbf24", "#60a5fa", "#a78bfa"]

  defp push_live_chart(socket) do
    curves = socket.assigns.live_curves

    series =
      curves
      |> Enum.sort_by(fn {vid, _} -> vid end)
      |> Enum.with_index()
      |> Enum.map(fn {{vid, data}, i} ->
        color = Enum.at(@curve_colors, rem(i, length(@curve_colors)))

        %{
          name: "v_#{vid}",
          type: "line",
          showSymbol: false,
          smooth: true,
          lineStyle: %{color: color, width: 2},
          data: data
        }
      end)

    chart_option = %{
      backgroundColor: "transparent",
      tooltip: %{trigger: "axis"},
      legend: %{
        data: Enum.map(series, & &1.name),
        textStyle: %{color: "#a1a1aa", fontSize: 10},
        top: 0,
        right: 0
      },
      grid: %{top: 30},
      xAxis: %{type: "value", name: "Step", nameLocation: "center", nameGap: 25},
      yAxis: %{type: "log", name: "Loss", nameLocation: "center", nameGap: 45, axisLabel: %{formatter: "{value}"}},
      series: series
    }

    push_event(socket, "chart-data-trial-loss-chart", chart_option)
  end


  defp safe_fmt(nil), do: "-"
  defp safe_fmt(l) when is_float(l), do: :erlang.float_to_binary(l, decimals: 6)
  defp safe_fmt(l), do: to_string(l)

  defp short_model(nil), do: "-"

  defp short_model(m),
    do:
      m
      |> String.replace("claude-", "")
      |> String.replace("gpt-", "gpt")
      |> String.replace("-preview", "")

  defp fmt_duration(nil), do: "-"
  defp fmt_duration(s) when is_number(s) and s < 60, do: "#{round(s)}s"
  defp fmt_duration(s) when is_number(s), do: "#{div(round(s), 60)}m#{rem(round(s), 60)}s"

  defp short_gpu(nil), do: "-"

  defp short_gpu(label) when is_binary(label) do
    cond do
      String.contains?(label, "cuda") -> "🟢 CUDA"
      String.contains?(label, "rocm") -> "🟠 ROCm"
      true -> label
    end
  end

  defp fmt_time(nil, _tz), do: ""

  defp fmt_time(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, "%H:%M:%S")
      _ -> Calendar.strftime(dt, "%H:%M:%S")
    end
  end

  defp fmt_time(_, _tz), do: ""


  defp models_for_backend(:copilot) do
    Jido.GHCopilot.Models.all()
    |> Enum.map(fn {name, id, mult} ->
      label = "#{name}#{if mult > 1, do: " (#{mult}x)", else: ""}"
      {id, label}
    end)
  end

  defp models_for_backend(:claude) do
    [
      {"sonnet", "Sonnet 4"},
      {"claude-sonnet-4-thinking", "Sonnet 4 (thinking)"},
      {"opus", "Opus 4"}
    ]
  end

  defp models_for_backend(:gemini) do
    [
      {"gemini-2.5-pro", "Gemini 2.5 Pro"},
      {"gemini-2.5-flash", "Gemini 2.5 Flash"}
    ]
  end

  defp default_tag do
    {{_y, m, d}, _} = :calendar.local_time()
    month = Enum.at(~w(jan feb mar apr may jun jul aug sep oct nov dec), m - 1)
    "#{month}#{d}"
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-7xl mx-auto p-6 space-y-5">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-zinc-100">🔬 ex_autoresearch</h1>
            <p class="text-zinc-400 text-sm">
              BEAM-native autonomous research
              <%= if @campaign_tag do %>
                · Campaign: <span class="text-indigo-400 font-mono">{@campaign_tag}</span>
              <% end %>
            </p>
          </div>
          <div class="flex items-center gap-2">
            <form phx-change="select_campaign">
              <select name="campaign"
                class="bg-zinc-800 border border-zinc-700 text-zinc-300 text-sm rounded-lg px-2 py-1.5 focus:ring-indigo-500 focus:border-indigo-500">
                <option value="new" selected={@selected_campaign_id == nil}>+ New campaign</option>
                <%= for c <- @campaigns do %>
                  <option value={c.id} selected={c.id == @selected_campaign_id}>
                    {c.tag} ({c.status})
                  </option>
                <% end %>
              </select>
            </form>
            <%= if @selected_campaign_id == nil do %>
              <form phx-change="update_new_tag">
                <input
                  type="text"
                  name="tag"
                  value={@new_campaign_tag}
                  placeholder="campaign tag"
                  class="bg-zinc-800 border border-zinc-700 text-zinc-300 text-sm rounded-lg px-2 py-1.5 w-32 focus:ring-indigo-500 focus:border-indigo-500"
                />
              </form>
            <% end %>
            <form phx-change="change_time_budget" class="flex items-center gap-1">
              <select name="time_budget"
                class="bg-zinc-800 border border-zinc-700 text-zinc-300 text-sm rounded-lg px-2 py-1.5 focus:ring-indigo-500 focus:border-indigo-500">
                <%= for {secs, label} <- [{15, "15s"}, {60, "1m"}, {120, "2m"}, {300, "5m"}, {600, "10m"}, {900, "15m"}] do %>
                  <option value={secs} selected={secs == @time_budget}><%= label %></option>
                <% end %>
              </select>
            </form>
            <form phx-change="change_backend">
              <select name="backend" id="backend-select"
                class="bg-zinc-800 border border-zinc-700 text-zinc-300 text-sm rounded-lg px-2 py-1.5 focus:ring-indigo-500 focus:border-indigo-500">
                <option value="copilot" selected={@current_backend == :copilot}>Copilot</option>
                <option value="claude" selected={@current_backend == :claude}>Claude</option>
                <option value="gemini" selected={@current_backend == :gemini}>Gemini</option>
              </select>
            </form>
            <div id={"model-wrapper-#{@current_backend}"}>
              <form phx-change="change_model">
                <select name="model" id={"model-select-#{@current_backend}"}
                  class="bg-zinc-800 border border-zinc-700 text-zinc-300 text-sm rounded-lg px-2 py-1.5 focus:ring-indigo-500 focus:border-indigo-500">
                  <%= for {id, label} <- @backend_models do %>
                    <option value={id} selected={id == @current_model}><%= label %></option>
                  <% end %>
                </select>
              </form>
            </div>
            <span class={["px-3 py-1 rounded-full text-sm font-medium", status_class(@agent_status)]}>
              {@agent_status}
            </span>
            <%= if @agent_status in [:idle, :stopping, :paused] do %>
              <button
                phx-click="start_research"
                class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg text-sm font-medium transition"
              >
                {if @selected_campaign_id, do: "▶ Continue", else: "▶ Start"}
              </button>
            <% else %>
              <button
                phx-click="stop_research"
                class="px-4 py-2 bg-red-600 hover:bg-red-500 text-white rounded-lg text-sm font-medium transition"
              >
                ⏹ Stop
              </button>
            <% end %>
            <%= if @campaign_tag do %>
              <a
                href={~p"/export/#{@campaign_tag}"}
                class="px-4 py-2 bg-zinc-700 hover:bg-zinc-600 text-zinc-200 rounded-lg text-sm font-medium transition"
              >
                📦 Export
              </a>
            <% end %>
          </div>
        </div>

        <%!-- Stats --%>
        <div class="grid grid-cols-5 gap-4">
          <.stat label="Trials" value={@trial_count} />
          <.stat label="Best Loss" value={safe_fmt(@best_loss)} />
          <.stat label="Best Trial" value={(@best_version && "v_#{@best_version}") || "-"} />
          <.stat label="Current Step" value={@current_step || "-"} />
          <.stat label="Progress" value={(@current_progress && "#{@current_progress}%") || "-"} />
        </div>

        <%!-- Charts --%>
        <div class="grid grid-cols-2 gap-5">
          <div class="bg-zinc-900 rounded-xl border border-zinc-800 p-4">
            <h2 class="text-lg font-semibold text-zinc-200 mb-2">📈 Loss over Trials</h2>
            <div id="loss-chart" phx-hook="Chart" phx-update="ignore" style="width:100%; height:250px;">
            </div>
          </div>
          <div class="bg-zinc-900 rounded-xl border border-zinc-800 p-4">
            <h2 class="text-lg font-semibold text-zinc-200 mb-2">📉 Current Trial Loss</h2>
            <div id="trial-loss-chart" phx-hook="Chart" phx-update="ignore" style="width:100%; height:250px;">
            </div>
          </div>
        </div>

        <%!-- Trials + Agent log --%>
        <div class="grid grid-cols-5 gap-5">
          <div class="col-span-3 bg-zinc-900 rounded-xl border border-zinc-800 p-4">
            <h2 class="text-lg font-semibold text-zinc-200 mb-3">📊 Trials</h2>
            <div class="overflow-y-auto max-h-[22rem]">
              <table class="w-full text-sm">
                <thead>
                  <tr class="text-zinc-500 border-b border-zinc-800">
                    <th class="text-left py-1.5 px-2">Time</th>
                    <th class="text-left py-1.5 px-2">Version</th>
                    <th class="text-left py-1.5 px-2">Loss</th>
                    <th class="text-right py-1.5 px-2">Steps</th>
                    <th class="text-right py-1.5 px-2">Duration</th>
                    <th class="text-left py-1.5 px-2">GPU</th>
                    <th class="text-left py-1.5 px-2">Model</th>
                    <th class="text-center py-1.5 px-2"></th>
                  </tr>
                </thead>
                <tbody id="trials" phx-update="stream">
                  <tr
                    :for={{dom_id, t} <- @streams.trials}
                    id={dom_id}
                    phx-click="select_version"
                    phx-value-version={t[:version_id]}
                    class={[
                      "border-b border-zinc-800/50 cursor-pointer transition hover:bg-zinc-800/40",
                      t[:kept] && "bg-emerald-950/20",
                      @selected && @selected[:version_id] == t[:version_id] &&
                        "ring-1 ring-indigo-500 bg-indigo-950/20"
                    ]}
                  >
                    <td class="py-1.5 px-2 text-xs text-zinc-500 font-mono">
                      {fmt_time(t[:timestamp], @timezone)}
                    </td>
                    <td class="py-1.5 px-2">
                      <div class="font-mono text-xs text-zinc-400">
                        {"v_#{t[:version_id] || "?"}"}
                      </div>
                      <div class="text-xs text-zinc-500 truncate max-w-[12rem]">
                        {t[:description] || ""}
                      </div>
                    </td>
                    <td class="py-1.5 px-2 font-mono text-zinc-300 text-sm">{safe_fmt(t[:loss])}</td>
                    <td class="py-1.5 px-2 text-right text-zinc-500 text-xs">{t[:steps] || "-"}</td>
                    <td class="py-1.5 px-2 text-right text-zinc-500 text-xs">{fmt_duration(t[:training_seconds])}</td>
                    <td class="py-1.5 px-2 text-xs text-zinc-500">{short_gpu(t[:gpu])}</td>
                    <td class="py-1.5 px-2 text-xs text-zinc-500">{short_model(t[:model])}</td>
                    <td class="py-1.5 px-2 text-center">
                      {if t[:kept], do: "✅", else: if(t[:status] == :crashed, do: "💥", else: "❌")}
                    </td>
                  </tr>
                </tbody>
              </table>
              <div class="hidden only:block text-zinc-600 text-center py-8">
                No trials yet. Hit ▶ Start.
              </div>
            </div>
          </div>

          <div class="col-span-2 bg-zinc-900 rounded-xl border border-zinc-800 p-4">
            <h2 class="text-lg font-semibold text-zinc-200 mb-3">🤖 Agent Log</h2>
            <div class="overflow-y-auto max-h-[22rem] space-y-1">
              <%= if @agent_log == [] do %>
                <p class="text-zinc-600 text-center py-8">Waiting for agent activity...</p>
              <% else %>
                <div
                  :for={entry <- @agent_log}
                  class="text-xs font-mono text-zinc-400 py-0.5 leading-relaxed"
                >
                  {entry}
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Code + Architecture viewer --%>
        <div class="bg-zinc-900 rounded-xl border border-zinc-800 p-4">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-semibold text-zinc-200">📝 Trial Details</h2>
            <div class="flex items-center gap-3">
              <%= if @selected do %>
                <span class="font-mono text-sm text-indigo-400">v_{@selected[:version_id]}</span>
                <span class="text-xs text-zinc-500">loss: {safe_fmt(@selected[:loss])}</span>
                <span class="text-xs text-zinc-500">{short_model(@selected[:model])}</span>
                <span class={[
                  "text-xs px-1.5 py-0.5 rounded",
                  if(@selected[:kept],
                    do: "bg-emerald-900/50 text-emerald-400",
                    else: "bg-zinc-800 text-zinc-500"
                  )
                ]}>
                  {if @selected[:kept],
                    do: "kept",
                    else: if(@selected[:status] == :crashed, do: "crashed", else: "discarded")}
                </span>
              <% end %>
              <%= if @best_version do %>
                <button
                  phx-click="select_best"
                  class="text-xs px-2 py-1 rounded bg-zinc-800 hover:bg-zinc-700 text-zinc-400 transition"
                >
                  Show Best
                </button>
              <% end %>
            </div>
          </div>
          <%= if @selected do %>
            <div class="text-xs text-zinc-500 mb-3 italic">{@selected[:description]}</div>
            <div class="grid grid-cols-2 gap-4">
              <%!-- Source code --%>
              <div>
                <h3 class="text-sm font-medium text-zinc-400 mb-2">Source Code</h3>
                <div class="overflow-y-auto max-h-[24rem] bg-zinc-950 rounded-lg p-3 border border-zinc-800">
                  <pre class="text-xs font-mono text-zinc-300 whitespace-pre-wrap"><%= @selected[:code] %></pre>
                </div>
              </div>
              <%!-- Architecture diagram --%>
              <div>
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-sm font-medium text-zinc-400">Model Architecture</h3>
                  <%= if @selected[:mermaid] do %>
                    <button
                      phx-click={JS.dispatch("mermaid:export-svg", to: "#mermaid-#{@selected[:version_id]}")}
                      class="text-xs text-zinc-500 hover:text-zinc-300 transition-colors cursor-pointer"
                    >
                      Export SVG
                    </button>
                  <% end %>
                </div>
                <%= if @selected[:mermaid] do %>
                  <div
                    id={"mermaid-#{@selected[:version_id]}"}
                    phx-hook="Mermaid"
                    phx-update="ignore"
                    data-diagram={@selected[:mermaid]}
                    class="overflow-y-auto max-h-[24rem] bg-zinc-950 rounded-lg p-3 border border-zinc-800 flex justify-center"
                  >
                    <div class="text-zinc-500 text-sm">Rendering...</div>
                  </div>
                <% else %>
                  <div class="bg-zinc-950 rounded-lg p-3 border border-zinc-800 text-zinc-600 text-center py-8">
                    Architecture diagram not available for this trial
                  </div>
                <% end %>
              </div>
            </div>
          <% else %>
            <div class="text-zinc-600 text-center py-12">
              Click a trial or chart data point to view source code and architecture
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_class(:running), do: "bg-emerald-900 text-emerald-300"
  defp status_class(:stopping), do: "bg-amber-900 text-amber-300"
  defp status_class(:paused), do: "bg-blue-900 text-blue-300"
  defp status_class(_), do: "bg-zinc-800 text-zinc-400"

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div class="bg-zinc-900 rounded-xl border border-zinc-800 p-4">
      <div class="text-zinc-500 text-xs uppercase tracking-wider">{@label}</div>
      <div class="text-2xl font-bold text-zinc-100 mt-1">{@value}</div>
    </div>
    """
  end
end
