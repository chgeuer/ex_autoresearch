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

    cond do
      name == op -> "#{name}#{param_str}"
      op == "fn" -> "#{name}#{param_str}"
      true -> "#{name} (#{op})#{param_str}"
    end
  rescue
    _ -> safe_str(node.op)
  end

  defp get_node_name(node) do
    result =
      case node.name do
        f when is_function(f, 2) ->
          if is_function(node.op) do
            # For function-based ops (e.g. Axon.nx), use the resolved function label
            # instead of the generic generated name like "nx_0".
            op_label = safe_str(node.op)

            if op_label == "fn" and is_atom(node.op_name) do
              Atom.to_string(node.op_name)
            else
              op_label
            end
          else
            f.(:op_name, node.op_name)
          end

        name when is_binary(name) ->
          name

        _ ->
          if is_atom(node.op_name), do: Atom.to_string(node.op_name), else: safe_str(node.op)
      end

    safe_str(result)
  rescue
    _ ->
      op_label = safe_str(node.op)

      if op_label == "fn" and is_atom(node.op_name) do
        Atom.to_string(node.op_name)
      else
        op_label
      end
  end

  defp safe_str(v) when is_binary(v), do: v
  defp safe_str(v) when is_atom(v), do: Atom.to_string(v)
  defp safe_str(v) when is_function(v), do: function_label(v)
  defp safe_str(v), do: inspect(v)

  defp function_label(fun) do
    info = Function.info(fun)

    case info[:type] do
      :external ->
        "#{inspect(info[:module])}.#{info[:name]}/#{info[:arity]}"

      :local ->
        case info[:env] do
          [inner] when is_function(inner) ->
            function_label(inner)

          env ->
            # First try AST extraction (works for eval'd/dynamically compiled code)
            case extract_calls_from_env(env) do
              [{mod, name}] ->
                "#{inspect(mod)}.#{name}"

              [_ | _] = pairs ->
                pairs |> Enum.map(fn {m, f} -> "#{inspect(m)}.#{f}" end) |> Enum.join(", ")

              [] ->
                # For compiled closures, parse the Erlang fun name
                # e.g. "-transformer_block/3-fun-0-" -> "transformer_block"
                parse_closure_name(info[:name])
            end
        end
    end
  rescue
    _ -> "fn"
  end

  defp parse_closure_name(name) when is_atom(name) do
    case Atom.to_string(name) do
      "-" <> rest ->
        case String.split(rest, "/", parts: 2) do
          [fun_name, _] -> fun_name
          _ -> "fn"
        end

      _ ->
        "fn"
    end
  end

  defp parse_closure_name(_), do: "fn"

  defp extract_calls_from_env(env) when is_list(env) do
    env
    |> Enum.flat_map(fn
      f when is_function(f) ->
        fi = Function.info(f)
        extract_calls_from_env(fi[:env])

      term ->
        extract_remote_calls(term)
    end)
    |> Enum.uniq()
    |> Enum.reject(fn {mod, _} -> mod in [Axon, Axon.Activations, :erlang] end)
  end

  defp extract_remote_calls(ast) when is_list(ast), do: Enum.flat_map(ast, &extract_remote_calls/1)

  defp extract_remote_calls({:call, _, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args}) do
    [{mod, fun}] ++ extract_remote_calls(args)
  end

  defp extract_remote_calls(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> extract_remote_calls()
  end

  defp extract_remote_calls(_), do: []
end
