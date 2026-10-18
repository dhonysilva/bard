defmodule Bard.Graph do
  @moduledoc """
  The project DAG, built from each node's `depends_on`.

  Edges run from parent to child (`stg_orders -> orders`). The graph is
  built from Bard's own nodes, not from dbt's `parent_map`, so the same
  code serves every loader.
  """

  alias Bard.Node

  @type t :: Graph.t()
  @type id :: String.t()
  @type depth :: :infinity | non_neg_integer()

  @doc """
  Builds the graph. Fails when a node depends on an unknown node or when
  the dependencies form a cycle.
  """
  @spec build(%{optional(id) => Node.t()}) ::
          {:ok, t()} | {:error, {:missing_parents, [{id, id}]} | {:cycle, [[id]]}}
  def build(nodes) when is_map(nodes) do
    missing =
      for {id, node} <- nodes, parent <- node.depends_on, not Map.has_key?(nodes, parent) do
        {id, parent}
      end

    if missing != [] do
      {:error, {:missing_parents, Enum.sort(missing)}}
    else
      graph =
        Enum.reduce(nodes, Graph.new(type: :directed), fn {id, node}, graph ->
          graph = Graph.add_vertex(graph, id)
          Enum.reduce(node.depends_on, graph, &Graph.add_edge(&2, &1, id))
        end)

      if Graph.is_acyclic?(graph) do
        {:ok, graph}
      else
        {:error, {:cycle, cycles(graph)}}
      end
    end
  end

  @doc "Direct parents of a node."
  @spec parents(t(), id) :: [id]
  def parents(graph, id), do: Graph.in_neighbors(graph, id)

  @doc "Direct children of a node."
  @spec children(t(), id) :: [id]
  def children(graph, id), do: Graph.out_neighbors(graph, id)

  @doc "Ancestors of `id` up to `depth` generations, excluding `id` itself."
  @spec ancestors(t(), id, depth) :: MapSet.t(id)
  def ancestors(graph, id, depth \\ :infinity), do: walk(graph, [id], depth, &parents/2)

  @doc "Descendants of `id` up to `depth` generations, excluding `id` itself."
  @spec descendants(t(), id, depth) :: MapSet.t(id)
  def descendants(graph, id, depth \\ :infinity), do: walk(graph, [id], depth, &children/2)

  @doc "Node ids in dependency order: every parent before its children."
  @spec topsort(t()) :: [id]
  def topsort(graph) do
    # A built graph is acyclic, so `Graph.topsort/1` never returns false here.
    Graph.topsort(graph)
  end

  # Breadth-first walk, so depth limits count generations exactly.
  defp walk(graph, start, depth, next) do
    do_walk(graph, start, depth, next, MapSet.new(start), MapSet.new())
  end

  defp do_walk(_graph, [], _depth, _next, _seen, acc), do: acc
  defp do_walk(_graph, _frontier, 0, _next, _seen, acc), do: acc

  defp do_walk(graph, frontier, depth, next, seen, acc) do
    found =
      frontier
      |> Enum.flat_map(&next.(graph, &1))
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.uniq()

    remaining = if depth == :infinity, do: :infinity, else: depth - 1

    do_walk(
      graph,
      found,
      remaining,
      next,
      MapSet.union(seen, MapSet.new(found)),
      MapSet.union(acc, MapSet.new(found))
    )
  end

  defp cycles(graph) do
    graph
    |> Graph.strong_components()
    |> Enum.filter(fn
      [single] -> Graph.edge(graph, single, single) != nil
      component -> length(component) > 1
    end)
    |> Enum.map(&Enum.sort/1)
  end
end
