defmodule ExAutoresearch.Agent.LLM.GeminiBackend do
  @moduledoc """
  Google Gemini backend via gemini_cli_sdk.

  Uses GeminiCliSdk.run/2 which spawns the `gemini` CLI and
  returns {:ok, text} or {:error, reason}.
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
    model = Keyword.get(opts, :model, "gemini-2.5-pro")
    Logger.info("Gemini backend ready: model=#{model}")
    {:ok, %__MODULE__{model: model, status: :idle}}
  end

  @impl true
  def handle_call({:prompt, text, requested_model}, from, %{status: :idle} = state) do
    model = requested_model || state.model
    state = %{state | model: model, status: :waiting, caller: from}

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

  defp run_query(prompt, _model) do
    options = %GeminiCliSdk.Options{
      cwd: File.cwd!()
    }

    case GeminiCliSdk.run(prompt, options) do
      {:ok, text} -> {:ok, String.trim(text)}
      {:error, reason} -> {:error, {:gemini_failed, reason}}
    end
  rescue
    e ->
      Logger.error("Gemini query failed: #{Exception.message(e)}")
      {:error, {:gemini_failed, Exception.message(e)}}
  end
end
