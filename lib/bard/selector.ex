defmodule Bard.Selector do
  @moduledoc """
  Evaluates dbt's node selection syntax against a project's graph.

      {:ok, ids} = Bard.Selector.select(project, select: ["+orders"], exclude: ["tag:slow"])

  The order of operations follows dbt:

    1. `--select` (all nodes when absent), minus `--exclude`
    2. indirect selection: with `:eager` (dbt's default), a test is added
       when any node it tests is selected; with `:empty`, none are added
    3. `--exclude` applied again, so excluded tests stay out
    4. `--resource-type` filter

  See `Bard.Selector.Parser` for the supported syntax.
  """

  use Boundary, top_level?: true, deps: [Bard], exports: []

  alias Bard.Graph
  alias Bard.Node
  alias Bard.Project
  alias Bard.Selector.Parser

  @type opts :: [
          select: [String.t()] | String.t() | nil,
          exclude: [String.t()] | String.t() | nil,
          resource_types: [Node.resource_type()] | nil,
          indirect_selection: :eager | :empty
        ]

  @doc "Returns the `unique_id`s selected by `opts`."

  @spec select(Project.t(), opts) :: {:ok, MapSet.t(String.t())} | {:error, term()}

  def select(%Project{} = project, opts \\ []) do
    with {:ok, selected} <- evaluate_or_all(project, opts[:select]),
         {:ok, excluded} <- evaluate_or_none(project, opts[:exclude]) do
      selected =
        selected
        |> MapSet.difference(excluded)
        |> add_indirect_tests(project, Keyword.get(opts, :indirect_selection, :eager))
        |> MapSet.difference(excluded)
        |> filter_resource_types(project, opts[:resource_types])

      {:ok, selected}
    end
  end

  @doc "Evaluates a parsed selector AST. Exposed for tests and tooling."

  @spec evaluate(Project.t(), Parser.ast()) :: MapSet.t(String.t())

  def evaluate(project, {:union, items}) do
    Enum.reduce(items, MapSet.new(), &MapSet.union(&2, evaluate(project, &1)))
  end

  def evaluate(project, {:intersection, [first | rest]}) do
    Enum.reduce(rest, evaluate(project, first), &MapSet.intersection(&2, evaluate(project, &1)))
  end

  def evaluate(%Project{graph: graph} = project, {:criterion, criterion}) do
    project
    |> Project.nodes()
    |> Enum.filter(&matches?(&1, criterion, project))
    |> Enum.map(& &1.unique_id)
    |> Enum.reduce(MapSet.new(), fn id, acc ->
      MapSet.union(acc, expand(graph, id, criterion))
    end)
  end

  defp evaluate_or_all(project, nil), do: {:ok, project.nodes |> Map.keys() |> MapSet.new()}
  defp evaluate_or_all(project, []), do: evaluate_or_all(project, nil)
  defp evaluate_or_all(project, select), do: parse_and_evaluate(project, select)

  defp evaluate_or_none(_project, nil), do: {:ok, MapSet.new()}
  defp evaluate_or_none(_project, []), do: {:ok, MapSet.new()}
  defp evaluate_or_none(project, exclude), do: parse_and_evaluate(project, exclude)

  defp parse_and_evaluate(project, input) do
    with {:ok, ast} <- Parser.parse(input), do: {:ok, evaluate(project, ast)}
  end

  defp expand(graph, id, %{at: true}) do
    family = MapSet.put(Graph.descendants(graph, id), id)

    Enum.reduce(family, family, fn member, acc ->
      MapSet.union(acc, Graph.ancestors(graph, member))
    end)
  end

  defp expand(graph, id, criterion) do
    MapSet.new([id])
    |> union_if(criterion.parents, &Graph.ancestors(graph, id, &1))
    |> union_if(criterion.children, &Graph.descendants(graph, id, &1))
  end

  defp union_if(set, nil, _fun), do: set
  defp union_if(set, depth, fun), do: MapSet.union(set, fun.(depth))

  defp matches?(node, %{method: :fqn, value: value}, _project) do
    parts = String.split(value, ".")

    (match?([_], parts) and glob?(hd(parts), node.name)) or
      prefix?(parts, node.fqn) or
      prefix?(parts, Enum.drop(node.fqn, 1))
  end

  defp matches?(node, %{method: :tag, value: value}, _project) do
    Enum.any?(Node.tags(node), &glob?(value, &1))
  end

  defp matches?(node, %{method: :path, value: value}, _project) do
    path = node.original_file_path || ""
    value = value |> String.trim_leading("./") |> String.trim_trailing("/")

    path == value or String.starts_with?(path, value <> "/") or glob?(value, path)
  end

  defp matches?(node, %{method: :resource_type, value: value}, _project) do
    Atom.to_string(node.resource_type) == value
  end

  defp matches?(node, %{method: :package, value: value}, _project) do
    glob?(value, node.package)
  end

  defp matches?(%Node{resource_type: :source} = node, %{method: :source, value: value}, _project) do
    case String.split(value, ".") do
      [source] ->
        glob?(source, node.source_name)

      [source, table] ->
        glob?(source, node.source_name) and glob?(table, node.name)

      [package, source, table] ->
        prefix?([package, source, table], [node.package, node.source_name, node.name])

      _ ->
        false
    end
  end

  defp matches?(_node, %{method: :source}, _project), do: false

  # Every selector part matches the fqn part at the same position.
  defp prefix?(parts, fqn) when length(parts) <= length(fqn) do
    parts |> Enum.zip(fqn) |> Enum.all?(fn {pattern, value} -> glob?(pattern, value) end)
  end

  defp prefix?(_parts, _fqn), do: false

  defp glob?(_pattern, nil), do: false

  defp glob?(pattern, value) do
    if String.contains?(pattern, "*") do
      regex =
        pattern
        |> String.split("*")
        |> Enum.map_join(".*", &Regex.escape/1)

      Regex.match?(~r/\A#{regex}\z/, value)
    else
      pattern == value
    end
  end

  defp add_indirect_tests(selected, _project, :empty), do: selected

  defp add_indirect_tests(selected, project, :eager) do
    project
    |> Project.nodes()
    |> Enum.filter(fn node ->
      node.resource_type == :test and Enum.any?(node.depends_on, &MapSet.member?(selected, &1))
    end)
    |> Enum.reduce(selected, &MapSet.put(&2, &1.unique_id))
  end

  defp filter_resource_types(selected, _project, nil), do: selected
  defp filter_resource_types(selected, _project, []), do: selected

  defp filter_resource_types(selected, project, types) do
    MapSet.filter(selected, fn id -> project.nodes[id].resource_type in types end)
  end
end
