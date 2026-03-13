defmodule ExAutoresearch.Agent.LLM do
  @moduledoc """
  Pluggable LLM backend for the researcher agent.

  Uses the GitHub Copilot CLI directly via System.cmd.
  Can be swapped for jido_ghcopilot when deps are wired up.
  """

  require Logger

  @default_model "claude-sonnet-4"
  @timeout_ms 120_000

  @doc """
  Send a prompt to the LLM and return the text response.

  Options:
  - model: LLM model to use (default: claude-sonnet-4)
  - system: system prompt to prepend
  - timeout_ms: timeout in milliseconds
  """
  def prompt(text, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    system = Keyword.get(opts, :system)
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    full_prompt =
      if system do
        "#{system}\n\n---\n\n#{text}"
      else
        text
      end

    args =
      ["-p", full_prompt, "--silent",
       "--deny-tool", "create", "--deny-tool", "edit",
       "--deny-tool", "write", "--deny-tool", "bash"] ++
        if(model, do: ["--model", model], else: [])

    Logger.debug("LLM prompt (#{String.length(full_prompt)} chars, model: #{model})")

    task = Task.async(fn ->
      System.cmd("copilot", args, stderr_to_stdout: true)
    end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, code}} ->
        Logger.error("Copilot CLI failed (exit #{code}): #{String.slice(output, 0, 200)}")
        {:error, {:copilot_failed, code, output}}

      nil ->
        Logger.error("Copilot CLI timed out after #{timeout}ms")
        {:error, :timeout}
    end
  rescue
    e ->
      Logger.error("LLM call failed: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  @doc "Check if the copilot CLI is available."
  def available? do
    System.find_executable("copilot") != nil
  end
end
