defmodule ExAutoresearch.Experiments.Loader do
  @moduledoc """
  Hot-loads experiment modules into the running BEAM.

  Takes Elixir source code, validates it, compiles it in-memory,
  and registers it in the version registry. No restarts needed.
  """

  require Logger

  @namespace "ExAutoresearch.Experiments"
  @required_callbacks [:config, :build, :optimizer]

  @doc """
  Compile and load an experiment module from source code.

  The code must define a module under ExAutoresearch.Experiments.V_*
  with the required callbacks: config/0, build/0, optimizer/0.

  Returns {:ok, module} or {:error, reason}.
  """
  @spec load(String.t(), String.t()) :: {:ok, module()} | {:error, term()}
  def load(version_id, code) do
    with :ok <- validate_syntax(code),
         :ok <- validate_namespace(code, version_id),
         {:ok, module} <- compile(code),
         :ok <- validate_callbacks(module) do
      Logger.info("Loaded experiment module: #{inspect(module)}")
      {:ok, module}
    end
  end

  @doc """
  Generate source code with the correct module name for a version ID.

  If the LLM outputs a module with a placeholder name, this replaces it.
  """
  @spec inject_version_id(String.t(), String.t()) :: String.t()
  def inject_version_id(code, version_id) do
    module_name = "#{@namespace}.V_#{version_id}"

    # Replace ANY defmodule declaration with our versioned name.
    # The LLM may generate arbitrary module names — we always override.
    String.replace(
      code,
      ~r/defmodule\s+[A-Z][\w.]+/,
      "defmodule #{module_name}",
      global: false
    )
  end

  # --- Private ---

  defp validate_syntax(code) do
    case Code.string_to_quoted(code) do
      {:ok, _ast} ->
        :ok

      {:error, {meta, msg, token}} ->
        line = Keyword.get(meta, :line, "?")
        {:error, {:syntax_error, "Line #{line}: #{msg} #{token}"}}
    end
  end

  defp validate_namespace(code, version_id) do
    expected = "#{@namespace}.V_#{version_id}"

    if String.contains?(code, expected) do
      :ok
    else
      {:error, {:wrong_namespace, "Module must be named #{expected}"}}
    end
  end

  defp compile(code) do
    try do
      [{module, _bytecode}] = Code.compile_string(code)
      {:ok, module}
    rescue
      e ->
        {:error, {:compile_error, Exception.message(e)}}
    end
  end

  defp validate_callbacks(module) do
    missing =
      @required_callbacks
      |> Enum.reject(&function_exported?(module, &1, 0))

    case missing do
      [] -> :ok
      fns -> {:error, {:missing_callbacks, fns}}
    end
  end
end
