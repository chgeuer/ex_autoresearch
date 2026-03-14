defmodule ExAutoresearch.Agent.LLM.ClaudeBackend do
  @moduledoc """
  Claude Code backend via claude_agent_sdk.

  Uses ClaudeAgentSDK.query/2 which spawns the `claude` CLI,
  streams messages, and collects the final text response.
  """

  use GenServer

  require Logger

  defstruct [:model, status: :idle, caller: nil]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model, "sonnet")
    Application.ensure_all_started(:claude_agent_sdk)
    Logger.info("Claude backend ready: model=#{model}")
    {:ok, %__MODULE__{model: model, status: :idle}}
  end

  @impl true
  def handle_call({:prompt, text, requested_model}, from, %{status: :idle} = state) do
    model = requested_model || state.model
    state = %{state | model: model, status: :waiting, caller: from}

    # Run query in a Task to not block the GenServer
    self_pid = self()
    Task.start(fn ->
      result = run_query(text, model)
      send(self_pid, {:query_result, result})
    end)

    {:noreply, state}
  end

  def handle_call({:prompt, _text, _model}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_info({:query_result, result}, %{caller: from} = state) when not is_nil(from) do
    GenServer.reply(from, result)
    {:noreply, %{state | status: :idle, caller: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp run_query(prompt, model) do
    options = %ClaudeAgentSDK.Options{
      model: model,
      max_turns: 1,
      allowed_tools: [],
      cwd: File.cwd!(),
      system_prompt: nil,
      timeout_ms: 120_000
    }

    text =
      prompt
      |> ClaudeAgentSDK.query(options)
      |> Enum.reduce("", fn msg, acc ->
        case msg do
          %{type: :assistant, subtype: :text, data: %{text: chunk}} ->
            acc <> chunk

          %{type: :result, subtype: :success, data: %{result: result_text}} ->
            acc <> (result_text || "")

          _ ->
            acc
        end
      end)

    {:ok, String.trim(text)}
  rescue
    e ->
      Logger.error("Claude query failed: #{Exception.message(e)}")
      {:error, {:claude_failed, Exception.message(e)}}
  end
end
