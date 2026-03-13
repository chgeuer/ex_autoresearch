defmodule ExAutoresearch.Agent.LLM do
  @moduledoc """
  LLM backend using jido_ghcopilot Server protocol.

  Maintains a persistent Copilot CLI connection with session management.
  Text is accumulated from streaming chunks until the turn completes.
  """

  use GenServer

  require Logger

  alias Jido.GHCopilot.Server.Connection

  @default_model "claude-sonnet-4"

  defstruct [:conn, :session_id, :model, status: :disconnected, buffer: "", caller: nil]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a prompt and wait for the complete response.

  Options:
  - model: override the session model
  - system: system prompt (prepended to the user prompt)
  """
  def prompt(text, opts \\ []) do
    system = Keyword.get(opts, :system)

    full_prompt =
      if system do
        "#{system}\n\n---\n\n#{text}"
      else
        text
      end

    GenServer.call(__MODULE__, {:prompt, full_prompt}, :infinity)
  end

  @doc "Check if the connection is alive."
  def available? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # Server

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model, @default_model)
    state = %__MODULE__{model: model}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    cli_args = ["--allow-all-tools", "--allow-all-paths", "--allow-all-urls"]

    case Connection.start_link(cli_args: cli_args, cwd: File.cwd!()) do
      {:ok, conn} ->
        case Connection.create_session(conn, %{model: state.model}) do
          {:ok, session_id} ->
            :ok = Connection.subscribe(conn, session_id)
            Logger.info("LLM connected: model=#{state.model}, session=#{session_id}")
            {:noreply, %{state | conn: conn, session_id: session_id, status: :idle}}

          {:error, reason} ->
            Logger.error("LLM session creation failed: #{inspect(reason)}")
            Process.send_after(self(), :reconnect, 5_000)
            {:noreply, %{state | conn: conn, status: :error}}
        end

      {:error, reason} ->
        Logger.error("LLM connection failed: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, 5_000)
        {:noreply, %{state | status: :error}}
    end
  end

  @impl true
  def handle_call({:prompt, text}, from, %{status: :idle} = state) do
    Logger.debug("LLM prompt (#{String.length(text)} chars)")

    case Connection.send_prompt(state.conn, state.session_id, text) do
      {:ok, _msg_id} ->
        {:noreply, %{state | status: :waiting, buffer: "", caller: from}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prompt, _text}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  # Streaming events from Copilot

  @impl true
  def handle_info({:server_event, %{type: type, data: data}}, %{caller: from} = state) do
    case type do
      # Server protocol sends full message, not chunks
      "assistant.message" ->
        content = data["content"] || ""
        Logger.debug("LLM message: #{String.length(content)} chars")
        {:noreply, %{state | buffer: state.buffer <> content}}

      # Also handle chunk-based protocols (ACP mode)
      "assistant.message.chunk" ->
        chunk = data["chunkContent"] || data["content"] || ""
        {:noreply, %{state | buffer: state.buffer <> chunk}}

      "session.idle" when not is_nil(from) ->
        response = String.trim(state.buffer)
        Logger.debug("LLM turn complete: #{String.length(response)} chars")
        GenServer.reply(from, {:ok, response})
        {:noreply, %{state | status: :idle, buffer: "", caller: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:server_event, _event}, state) do
    {:noreply, state}
  end

  # Deny any tool calls — we only want text output
  def handle_info({:server_tool_call, tool_call}, state) do
    Logger.debug("LLM tool call denied: #{tool_call.tool_name}")
    Connection.respond_to_tool_call(state.conn, tool_call.request_id, %{
      "error" => "No tools available. Output code as text in your response."
    })
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    Logger.info("LLM reconnecting...")
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    Connection.stop(conn)
  end
  def terminate(_, _), do: :ok
end
