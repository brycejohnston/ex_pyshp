defmodule ExPyshp.DocumentationTest do
  use ExUnit.Case
  import ExPyshp.TestHelpers, only: [python: 2]

  doctest ExPyshp

  test "every library module, public function and public type has documentation" do
    for module <- library_modules() do
      {:docs_v1, _, _, _, module_doc, _, docs} = Code.fetch_docs(module)
      assert_documented(module_doc, inspect(module))
      {:ok, specs} = Code.Typespec.fetch_specs(module)
      spec_functions = MapSet.new(specs, fn {function, _} -> function end)

      for {{kind, name, arity}, _, _, doc, _} <- docs,
          kind in [:function, :type] do
        assert_documented(doc, "#{inspect(module)}.#{name}/#{arity}")
      end

      documented_functions =
        docs
        |> Enum.filter(fn {{kind, _, _}, _, _, _, _} -> kind == :function end)
        |> Enum.flat_map(fn {{:function, name, arity}, _, _, _, metadata} ->
          assert MapSet.member?(spec_functions, {name, arity}),
                 "Add a typespec for #{inspect(module)}.#{name}/#{arity}"

          for default_arity <- (arity - Map.get(metadata, :defaults, 0))..arity,
              do: {name, default_arity}
        end)
        |> MapSet.new()

      assert MapSet.new(module.__info__(:functions)) == documented_functions,
             "Add @doc entries for the exported functions in #{inspect(module)}"
    end
  end

  test "every embedded Python function has a docstring" do
    source =
      library_modules()
      |> Enum.filter(&function_exported?(&1, :code, 0))
      |> Enum.map_join("\n", & &1.code())

    missing =
      python(
        """
        import ast

        functions = [node for node in ast.walk(ast.parse(source))
                     if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]
        [node.name for node in functions if not (ast.get_docstring(node) or '').strip()]
        """,
        %{"source" => source}
      )

    assert missing == [], "Add docstrings for these Python functions: #{inspect(missing)}"
  end

  defp library_modules, do: Application.spec(:ex_pyshp, :modules) -- [ExPyshp.TestHelpers]

  defp assert_documented(doc, name) do
    assert is_map(doc), "Add documentation for #{name}"
    assert String.trim(Map.fetch!(doc, "en")) != "", "Documentation for #{name} must not be empty"
  end
end
