defmodule Bard.Build do
  @moduledoc """
  Builds models: joins the runner, materializations and an adapter.

      Bard.Build.run(project, ids, Bard.Adapter.Postgres, conn, threads: 4)

  Each layer stays ignorant of the others: the runner schedules functions,
  materializations return SQL, adapters execute it. This module is the only
  place that knows all three.

  `bard run` builds models only, like `dbt run`.

  Ephemeral models build nothing (dbt inlined them into their children's
  compiled SQL), but they still carry dependencies: in `stg -> eph -> mart`,
  `mart` must wait for `stg`. So every ephemeral model is scheduled as a no-op
  step, and left out of the results.
  """

  use Boundary,
    top_level?: true,
    deps: [Bard, Bard.Adapter, Bard.Materialization, Bard.Runner],
    exports: []

  alias Bard.Materialization
  alias Bard.Node
  alias Bard.Project
  alias Bard.Relation
  alias Bard.Runner

  @spec run(Project.t(), Enumerable.t(), module(), term(), keyword()) ::
          {:ok, %{String.t() => Runner.result()}} | {:error, term()}

  def run(%Project{} = project, ids, adapter, conn, opts \\ []) do
    nodes = runnable(project, ids)
    ephemeral = for node <- Project.nodes(project), ephemeral?(node), do: node.unique_id

    with :ok <- check_compiled(nodes),
         :ok <- prepare_schemas(nodes, adapter, conn) do
      results =
        Runner.run(project, Enum.map(nodes, & &1.unique_id) ++ ephemeral,
          threads: Keyword.get(opts, :threads, 4),
          retries: Keyword.get(opts, :retries, 0),
          execute: executor(adapter, conn, opts)
        )

      {:ok, Map.drop(results, ephemeral)}
    end
  end

  @doc "True for ephemeral models: scheduled for their dependencies, never built."
  @spec ephemeral?(Node.t()) :: boolean()
  def ephemeral?(%Node{resource_type: :model, config: %{materialized: :ephemeral}}), do: true
  def ephemeral?(%Node{}), do: false

  @doc "The models in `ids` that `bard run` builds."
  @spec runnable(Project.t(), Enumerable.t()) :: [Node.t()]
  def runnable(project, ids) do
    ids
    |> Enum.map(&project.nodes[&1])
    |> Enum.filter(&(&1.resource_type == :model and not ephemeral?(&1)))
  end

  @doc "The function the runner calls for each node."
  @spec executor(module(), term(), keyword()) :: (Node.t() -> {:ok, map()} | {:error, term()})
  def executor(adapter, conn, opts) do
    fn %Node{} = node -> build(node, adapter, conn, opts) end
  end

  # Ephemeral models have no relation: nothing to describe or build.
  defp build(%Node{} = node, adapter, conn, opts) do
    if ephemeral?(node) do
      {:ok, %{}}
    else
      with {:ok, relation} <- Relation.parse(node.relation_name),
           {:ok, existing} <- adapter.describe(conn, relation) do
        case Materialization.plan(node, existing, opts) do
          {:run, statements} -> adapter.transaction(conn, statements)
          :skip -> {:ok, %{}}
          {:error, _} = error -> error
        end
      end
    end
  end

  # Every model must come from `dbt compile`; one missing means the manifest
  # is from `dbt parse`, so fail before touching the warehouse.
  defp check_compiled(nodes) do
    case for(%Node{compiled_code: nil, name: name} <- nodes, do: name) do
      [] -> :ok
      missing -> {:error, {:not_compiled, Enum.sort(missing)}}
    end
  end

  # Concurrent `create schema if not exists` can race in Postgres, so schemas
  # are created one by one before any model runs.
  defp prepare_schemas(nodes, adapter, conn) do
    nodes
    |> Enum.map(&Relation.parse(&1.relation_name))
    |> Enum.uniq_by(fn
      {:ok, relation} -> {relation.database, relation.schema}
      error -> error
    end)
    |> Enum.reduce_while(:ok, fn
      {:ok, relation}, :ok ->
        case adapter.ensure_schema(conn, relation) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      error, :ok ->
        {:halt, error}
    end)
  end
end
