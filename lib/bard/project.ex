defmodule Bard.Project do
  @moduledoc """
  A loaded project: its nodes keyed by `unique_id` and the DAG between them.

  Build one with `load/2`, which runs a loader and then `Bard.Graph.build/1`,
  so a `%Bard.Project{}` always carries a valid, acyclic graph.

  The loader is passed in rather than defaulted, so this module (the
  root `Bard` boundary) never depends on any loader.
  """

  alias Bard.Graph
  alias Bard.Node

  @type t :: %__MODULE__{
          name: String.t() | nil,
          root: Path.t() | nil,
          dbt_version: String.t() | nil,
          schema_version: String.t() | nil,
          nodes: %{optional(String.t()) => Node.t()},
          graph: Graph.t() | nil
        }

  defstruct [:name, :root, :dbt_version, :schema_version, :graph, nodes: %{}]

  @doc """
  Loads a project with the given loader and builds its graph.

      Bard.Project.load(Bard.Loader.Manifest, project_dir: "../analytics_dbt")
  """

  @spec load(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(loader, opts) when is_atom(loader) and is_list(opts) do
    with {:ok, %__MODULE__{} = project} <- loader.load(opts),
         {:ok, graph} <- Graph.build(project.nodes) do
      {:ok, %{project | graph: graph}}
    end
  end

  @spec fetch_node(t(), String.t()) :: {:ok, Node.t()} | :error
  def fetch_node(%__MODULE__{nodes: nodes}, unique_id), do: Map.fetch(nodes, unique_id)

  @spec nodes(t()) :: [Node.t()]
  def nodes(%__MODULE__{nodes: nodes}), do: Map.values(nodes)
end
