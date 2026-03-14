defmodule ExAutoresearch.Model.Display do
  @moduledoc """
  Generate visual representations of Axon models.

  Produces:
  - ASCII table via Axon.Display.as_table (for the code viewer)
  - Mermaid diagram (for rendering in the browser)
  """

  @doc """
  Generate an ASCII table of model layers.
  Returns a string suitable for <pre> display.
  """
  @spec as_table(Axon.t(), map()) :: String.t()
  def as_table(model, template) do
    Axon.Display.as_table(model, template)
  rescue
    _ -> "(table generation failed)"
  end

  @doc """
  Generate a Mermaid flowchart diagram from an Axon model.
  Returns a Mermaid diagram string.
  """
  @spec as_mermaid(Axon.t()) :: String.t()
  def as_mermaid(%Axon{output: output_id, nodes: nodes}) do
    sorted = nodes |> Enum.sort_by(fn {id, _} -> id end)

    node_lines =
      sorted
      |> Enum.map(fn {id, node} ->
        label = format_node_label(node)
        "    n#{id}[\"#{label}\"]"
      end)

    edge_lines =
      sorted
      |> Enum.flat_map(fn {id, node} ->
        Enum.map(node.parent, fn parent_id ->
          "    n#{parent_id} --> n#{id}"
        end)
      end)

    _style_lines =
      sorted
      |> Enum.map(fn {id, node} ->
        style_class = case node.op do
          :input -> ":::input"
          :dense -> ":::dense"
          :embedding -> ":::embed"
          :layer_norm -> ":::norm"
          :add -> ":::add"
          op when is_atom(op) and op in [:relu, :gelu, :silu, :tanh, :sigmoid] -> ":::activation"
          :nx -> ":::custom"
          f when is_function(f) -> ":::custom"
          _ -> ""
        end
        if style_class != "", do: "    n#{id}#{style_class}", else: nil
      end)
      |> Enum.reject(&is_nil/1)

    # Highlight the output node
    output_style = "    style n#{output_id} stroke:#818cf8,stroke-width:2px"

    lines = ["graph TD"] ++ node_lines ++ edge_lines ++ [output_style]
    Enum.join(lines, "\n")
  end
  def as_mermaid(_), do: "graph TD\n    empty[No model]"

  defp format_node_label(node) do
    name = get_node_name(node)
    op = safe_str(node.op)

    params =
      node.parameters
      |> Enum.map(fn p ->
        shape = if p.shape, do: inspect(p.shape), else: "?"
        pname = safe_str(p.name)
        "#{pname}: #{shape}"
      end)

    param_str = if params != [], do: "\\n#{Enum.join(params, ", ")}", else: ""

    "#{name} (#{op})#{param_str}"
  rescue
    _ -> safe_str(node.op)
  end

  defp get_node_name(node) do
    result =
      case node.name do
        f when is_function(f, 2) -> f.(:op_name, node.op_name)
        name when is_binary(name) -> name
        _ -> safe_str(node.op)
      end

    safe_str(result)
  rescue
    _ -> safe_str(node.op)
  end

  defp safe_str(v) when is_binary(v), do: v
  defp safe_str(v) when is_atom(v), do: Atom.to_string(v)
  defp safe_str(v) when is_function(v), do: "fn"
  defp safe_str(v), do: inspect(v)
end
