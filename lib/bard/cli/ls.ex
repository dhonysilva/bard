defmodule Bard.CLI.Ls do
  @moduledoc """
  `bard ls`: lists selected nodes, mirroring `dbt ls`.

  Output formats match dbt's so the two can be diffed line by line:

    * `:selector` (default) - `jaffle_shop.staging.stg_orders`, or
      `source:jaffle_shop.ecom.raw_stores` for sources
    * `:name` - the node name
    * `:path` - the file the node is defined in
    * `:json` - one JSON object per line
  """

  alias Bard.Node
  alias Bard.Project
  alias Bard.Selector

  @type output :: :selector | :name | :path | :json

  @spec run(Project.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}

  def run(%Project{} = project, opts) do
    output = Keyword.get(opts, :output, :selector)

    with {:ok, ids} <- Selector.select(project, opts) do
      lines =
        ids
        |> Enum.map(&project.nodes[&1])
        |> Enum.map(&format(&1, output))
        |> Enum.sort()

      {:ok, lines}
    end
  end

  @spec format(Node.t(), output) :: String.t()
  def format(%Node{resource_type: :source} = node, :selector),
    do: "source:" <> Enum.join([node.package, node.source_name, node.name], ".")

  def format(%Node{} = node, :selector), do: Enum.join(node.fqn, ".")
  def format(%Node{} = node, :name), do: node.name
  def format(%Node{} = node, :path), do: node.original_file_path || ""

  def format(%Node{} = node, :json) do
    Jason.encode!(%{
      unique_id: node.unique_id,
      name: node.name,
      resource_type: node.resource_type,
      package_name: node.package,
      original_file_path: node.original_file_path,
      tags: Node.tags(node),
      depends_on: %{nodes: node.depends_on},
      config: %{materialized: node.config.materialized, enabled: node.config.enabled}
    })
  end
end
