defmodule ExAutoresearch.Agent.LLM do
  @moduledoc """
  Pluggable LLM backend manager.

  Delegates to backend modules that implement the LLM.Backend behaviour.
  The active backend can be switched at runtime via `set_backend/2`.

  Supported backends:
  - `:copilot` — GitHub Copilot via jido_ghcopilot Server protocol
  - `:claude` — Anthropic Claude via jido_claude
  - `:gemini` — Google Gemini via jido_gemini

  Each backend+model combination is a separate GenServer connection.
  Switching is instant — the next prompt goes to the new backend.
  """

  use GenServer

  require Logger

  alias ExAutoresearch.Agent.LLM.CopilotBackend

  @prompt_schema NimbleOptions.new!(
                   system: [type: :string, doc: "System prompt prepended to user prompt"],
                   model: [type: :string, doc: "Model override for this prompt"]
                 )

  @type backend :: :copilot | :claude | :gemini
  @type backend_state :: %{
          backend: backend(),
          model: String.t(),
          pid: pid() | nil,
          status: :connecting | :idle | :error
        }

  defstruct [:active, backends: %{}]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a prompt and wait for the complete text response.

  ## Options
  #{NimbleOptions.docs(@prompt_schema)}
  """
  @spec prompt(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prompt(text, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @prompt_schema)
    system = Keyword.get(opts, :system)
    model = Keyword.get(opts, :model)

    full_prompt = if system, do: "#{system}\n\n---\n\n#{text}", else: text

    GenServer.call(__MODULE__, {:prompt, full_prompt, model}, :timer.minutes(5))
  end

  @doc "Switch to a different backend and model. Takes effect on next prompt."
  @spec set_backend(backend(), String.t()) :: :ok
  def set_backend(backend, model) when backend in [:copilot, :claude, :gemini] do
    GenServer.call(__MODULE__, {:set_backend, backend, model})
  end

  @doc "Get current backend and model."
  @spec current() :: {backend(), String.t()}
  def current do
    GenServer.call(__MODULE__, :current)
  end

  @doc "Check if any backend is connected."
  @spec available?() :: boolean()
  def available? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc "List all available backends with their connection status."
  @spec backends() :: [{backend(), String.t(), :idle | :connecting | :error | :not_started}]
  def backends do
    GenServer.call(__MODULE__, :list_backends)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    backend = Keyword.get(opts, :backend, :copilot)
    model = Keyword.get(opts, :model, "claude-sonnet-4")

    state = %__MODULE__{
      active: {backend, model},
      backends: %{}
    }

    # Start the default backend
    {:ok, state, {:continue, {:ensure_backend, backend, model}}}
  end

  @impl true
  def handle_continue({:ensure_backend, backend, model}, state) do
    state = ensure_backend_started(state, backend, model)
    {:noreply, state}
  end

  @impl true
  def handle_call({:prompt, text, model_override}, from, state) do
    {backend, default_model} = state.active
    model = model_override || default_model

    state = ensure_backend_started(state, backend, model)

    case get_backend_pid(state, backend) do
      {:ok, pid} ->
        Task.start(fn ->
          result = GenServer.call(pid, {:prompt, text, model}, :timer.minutes(4))
          GenServer.reply(from, result)
        end)

        {:noreply, state}

      :error ->
        {:reply, {:error, {:backend_not_available, backend}}, state}
    end
  end

  @impl true
  def handle_call({:set_backend, backend, model}, _from, state) do
    Logger.info("LLM backend → #{backend}:#{model}")
    state = %{state | active: {backend, model}}
    state = ensure_backend_started(state, backend, model)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.active, state}
  end

  @impl true
  def handle_call(:list_backends, _from, state) do
    {active_backend, _} = state.active

    list =
      [:copilot, :claude, :gemini]
      |> Enum.map(fn b ->
        status =
          case Map.get(state.backends, b) do
            %{status: s} -> s
            nil -> :not_started
          end

        {b, b == active_backend, status}
      end)

    {:reply, list, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # A backend process died — mark it as error
    {backend, _} =
      Enum.find(state.backends, {nil, nil}, fn {_k, v} -> v.pid == pid end) || {nil, nil}

    if backend do
      Logger.warning("LLM backend #{backend} died: #{inspect(reason, limit: 3)}")

      state =
        put_in(state.backends[backend], %{state.backends[backend] | pid: nil, status: :error})

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  # --- Private ---

  defp ensure_backend_started(state, backend, model) do
    case Map.get(state.backends, backend) do
      %{pid: pid, status: :idle} when is_pid(pid) ->
        state

      _ ->
        case start_backend(backend, model) do
          {:ok, pid} ->
            Process.monitor(pid)
            put_in(state.backends[backend], %{pid: pid, model: model, status: :idle})

          {:error, reason} ->
            Logger.error("Failed to start #{backend} backend: #{inspect(reason)}")
            put_in(state.backends[backend], %{pid: nil, model: model, status: :error})
        end
    end
  end

  defp start_backend(:copilot, model) do
    CopilotBackend.start_link(model: model)
  end

  defp start_backend(:claude, model) do
    ExAutoresearch.Agent.LLM.ClaudeBackend.start_link(model: model)
  end

  defp start_backend(:gemini, model) do
    ExAutoresearch.Agent.LLM.GeminiBackend.start_link(model: model)
  end

  defp get_backend_pid(state, backend) do
    case Map.get(state.backends, backend) do
      %{pid: pid} when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end
end
