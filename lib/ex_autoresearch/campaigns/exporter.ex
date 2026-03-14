defmodule ExAutoresearch.Campaigns.Exporter do
  @moduledoc """
  Export a campaign's successful iteration chain as a ZIP of numbered markdown files.

  000.md = baseline, 001.md = first improvement, etc.
  Each file contains metadata, source code, and mermaid architecture diagram.
  """

  alias ExAutoresearch.Experiments.Registry
  alias ExAutoresearch.Model.Display

  require Ash.Query

  @doc """
  Build a ZIP binary for the given campaign tag.
  Returns `{:ok, zip_binary}` or `{:error, reason}`.
  """
  @spec export_zip(String.t()) :: {:ok, binary()} | {:error, term()}
  def export_zip(campaign_tag) do
    case Registry.get_campaign(campaign_tag) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, campaign} -> build_zip(campaign)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_zip(campaign) do
    kept_trials =
      ExAutoresearch.Research.Trial
      |> Ash.Query.filter(campaign_id == ^campaign.id and kept == true)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!()

    files =
      kept_trials
      |> Enum.with_index()
      |> Enum.map(fn {trial, idx} ->
        filename = String.pad_leading(Integer.to_string(idx), 3, "0") <> ".md"
        content = trial_to_markdown(trial, idx)
        {String.to_charlist(filename), content}
      end)

    case :zip.create(~c"campaign.zip", files, [:memory]) do
      {:ok, {_name, zip_binary}} -> {:ok, zip_binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trial_to_markdown(trial, idx) do
    mermaid = build_mermaid_for_trial(trial)

    label = if idx == 0, do: "Baseline", else: "Iteration #{idx}"
    loss_str = fmt_loss(trial.final_loss)

    lines = [
      "# #{label}: V_#{trial.version_id} (loss: #{loss_str})",
      "",
      "> #{trial.description || "No description"}",
      "",
      "| Metric | Value |",
      "|--------|-------|",
      "| Loss | #{fmt_loss(trial.final_loss)} |",
      "| Steps | #{trial.num_steps || "-"} |",
      "| Training time | #{fmt_seconds(trial.training_seconds)} |",
      "| Model | #{trial.model || "-"} |",
      "| Timestamp | #{trial.inserted_at} |",
      ""
    ]

    lines =
      if trial.reasoning && trial.reasoning != trial.description do
        lines ++ ["## Reasoning", "", trial.reasoning, ""]
      else
        lines
      end

    lines = lines ++ ["## Source Code", "", "```elixir", String.trim(trial.code || ""), "```", ""]

    lines =
      if mermaid do
        lines ++ ["## Architecture", "", "```mermaid", mermaid, "```", ""]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp build_mermaid_for_trial(trial) do
    if trial.code do
      case Registry.get_module(trial.version_id) do
        {:ok, module} -> safe_mermaid(module)
        :not_loaded ->
          case Registry.reload_module(trial) do
            {:ok, module} -> safe_mermaid(module)
            _ -> nil
          end
      end
    end
  rescue
    _ -> nil
  end

  defp safe_mermaid(module) do
    Display.as_mermaid(module.build())
  rescue
    _ -> nil
  end

  defp fmt_loss(nil), do: "-"
  defp fmt_loss(l) when is_float(l), do: :erlang.float_to_binary(l, decimals: 8)
  defp fmt_loss(l), do: to_string(l)

  defp fmt_seconds(nil), do: "-"
  defp fmt_seconds(s) when is_float(s), do: "#{:erlang.float_to_binary(s, decimals: 1)}s"
  defp fmt_seconds(s), do: "#{s}s"
end
