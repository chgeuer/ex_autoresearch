defmodule ExAutoresearch.Agent.Prompts do
  @moduledoc """
  Reads and composes prompts from priv/prompts/*.md files.

  Prompts are editable at runtime - changes are picked up on next read.
  """

  @prompts_dir "priv/prompts"
  @pitfalls_path Path.join(@prompts_dir, "pitfalls.md")

  import MDEx.Sigil

  def read(filename) do
    path = Path.join([@prompts_dir, filename])

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> "# #{filename} not found"
    end
  end

  @doc """
  Distill crash patterns from trial history into pitfalls.md.

  Groups crashes by error pattern, deduplicates, and writes a concise
  list of "do NOT do this" rules that the LLM sees in every prompt.
  """
  def distill_pitfalls(campaign_id) do
    alias ExAutoresearch.Experiments.Registry

    crashed =
      Registry.all_trials(campaign_id)
      |> Enum.filter(&(&1.status == :crashed and &1.error != nil and &1.error != ""))

    if crashed == [] do
      File.rm(@pitfalls_path)
      :ok
    else
      patterns = extract_patterns(crashed)

      if patterns != [] do
        pitfall_items =
          Enum.map_join(patterns, "\n", fn {pattern, examples} ->
            count = length(examples)
            example = hd(examples)
            "- **#{pattern}** (#{count} crash#{if count > 1, do: "es"}):\n  #{example}\n"
          end)

        assigns = %{pitfall_items: pitfall_items}

        content = ~MD"""
        ## Known Pitfalls — DO NOT repeat these mistakes

        The following patterns have caused crashes in this campaign. Avoid them.

        <%= @pitfall_items %>
        """MD

        File.write!(@pitfalls_path, content)
      else
        File.rm(@pitfalls_path)
      end
    end
  end

  defp extract_patterns(crashed_trials) do
    crashed_trials
    |> Enum.map(fn t ->
      error = t.error || ""
      pattern = classify_error(error)
      # Use the first meaningful line as the example, skip binary gibberish
      example =
        error
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 =~ ~r/^[\s]*<<\d/ or &1 =~ ~r/:erlang\.\+\+/))
        |> Enum.take(2)
        |> Enum.join(" | ")
        |> String.slice(0, 200)
      {pattern, example}
    end)
    |> Enum.reject(fn {_, example} -> example == "" or example =~ "Stale running" end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reject(fn {pattern, _} -> String.starts_with?(pattern, "INFRASTRUCTURE BUG") end)
    |> Enum.sort_by(fn {_, examples} -> -length(examples) end)
    |> Enum.take(10)
  end

  defp classify_error(error) do
    cond do
      error =~ "[jit_compile]" or error =~ "[model_build]" ->
        # These are LLM code errors — the model definition is wrong
        cond do
          error =~ "Axon.embedding" and error =~ "computed" ->
            "Axon.embedding on computed input (use Axon.nx with Nx.take instead)"

          error =~ "Axon.nx" and error =~ "compiling layer" ->
            "Invalid operation inside Axon.nx callback (shape/type error at JIT time)"

          error =~ "shape" or error =~ "Shape" ->
            "Tensor shape mismatch in model definition"

          error =~ "CompileError" or error =~ "undefined function" ->
            "Compilation error (undefined function or bad syntax)"

          error =~ "FunctionClauseError" ->
            "FunctionClauseError (wrong argument types to Nx/Axon function)"

          true ->
            "Model build/JIT error"
        end

      error =~ "[mid_training]" ->
        # These crash during training — might be LLM code OR infra
        cond do
          error =~ "ArithmeticError" or error =~ "NaN" or error =~ "nan" ->
            "Numerical instability during training (NaN/Inf — try lower learning rate)"

          error =~ "out of memory" or error =~ "OOM" ->
            "Out of GPU memory (reduce batch_size or model dimensions)"

          error =~ "serialize" or error =~ "erlang.++" ->
            "INFRASTRUCTURE BUG: Serialization crash (not an LLM code issue)"

          true ->
            "Training crash (check error details)"
        end

      error =~ "ArgumentError" or error =~ "argument error" ->
        "ArgumentError (likely invalid Nx/Axon operation or shape mismatch)"

      error =~ "serialize" or error =~ "erlang.++" ->
        "INFRASTRUCTURE BUG: Serialization issue (not an LLM code issue)"

      true ->
        "Other crash"
    end
  end

  def system_prompt do
    [read("system.md"), read("strategy.md"), read("constraints.md"), read("pitfalls.md")]
    |> Enum.reject(&(&1 =~ "not found"))
    |> Enum.join("\n\n")
  end

  def build_proposal_prompt(history, best, kept_versions, version_id) do
    template_code = read("template.md")
    recent = if history != [], do: Enum.take(history, -20), else: []
    notable = kept_versions |> Enum.filter(& &1.code) |> Enum.take(3)

    assigns = %{
      best:
        best &&
          %{
            version_id: best.version_id,
            loss: safe_round(best.final_loss, 6),
            code: best.code
          },
      has_history: history != [],
      recent:
        Enum.map(recent, fn e ->
          %{
            version_id: e.version_id,
            loss: safe_round(e.final_loss, 6) || "crash",
            steps: e.num_steps || 0,
            model: short_model(e.model),
            desc: String.slice(e.description || "", 0, 80),
            status: if(e.kept, do: "✅ kept", else: "❌ discarded")
          }
        end),
      total: length(history),
      kept_count: Enum.count(history, & &1.kept),
      notable:
        Enum.map(notable, fn e ->
          %{
            version_id: e.version_id,
            loss: safe_round(e.final_loss, 6),
            description: e.description,
            code: e.code
          }
        end),
      version_id: version_id,
      template_code: template_code
    }

    ~MD"""
    <%= if @best do %>
    ## Current best version (v_<%= @best.version_id %>, loss: <%= @best.loss %>)

    ```elixir
    <%= @best.code %>
    ```
    <% else %>
    No experiments yet. Generate the baseline using the template below.
    <% end %>

    <%= if @has_history do %>
    ## Experiment history (<%= @total %> total, <%= @kept_count %> kept, showing last 20)

    | Version | Loss | Steps | Model | Description | Status |
    |---------|------|-------|-------|-------------|--------|
    <%= for r <- @recent do %>| v_<%= r.version_id %> | <%= r.loss %> | <%= r.steps %> | <%= r.model %> | <%= r.desc %> | <%= r.status %> |
    <% end %>
    <% end %>
    <%= if @notable != [] do %>

    ## Notable kept versions (source code)

    <%= for e <- @notable do %>
    ### v_<%= e.version_id %> (loss: <%= e.loss %>) - <%= e.description %>

    ```elixir
    <%= e.code %>
    ```
    <% end %>
    <% end %>

    ## Your task

    Generate a NEW experiment version. Your module must be named ExAutoresearch.Experiments.V_<%= @version_id %>.

    Output ONLY the complete defmodule block - no explanation outside the code.
    Put your reasoning in the @moduledoc string.

    <%= @template_code %>
    """MD
  end

  defp safe_round(val, decimals) when is_float(val), do: Float.round(val, decimals)
  defp safe_round(val, _decimals) when is_integer(val), do: val / 1
  defp safe_round(_, _), do: nil

  defp short_model(nil), do: "-"

  defp short_model(m) do
    m
    |> String.replace("claude-", "")
    |> String.replace("gpt-", "gpt")
    |> String.replace("-preview", "")
  end
end
