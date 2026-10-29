defmodule Bard.Test.RunParity do
  @moduledoc """
  The Phase 2 gate: `dbt run` and `bard run` must build identical data.

  dbt builds into one target, Bard into another (two schemas), from the same
  project. Every model is then compared on row count and a checksum of all
  its rows.
  """

  use Boundary, top_level?: true, deps: [Bard, Bard.Loader, Bard.Profile, Bard.Adapter, Bard.CLI]

  alias Bard.Loader
  alias Bard.Project
  alias Bard.Relation

  def dbt!(project_dir, args) do
    dbt = System.get_env("BARD_DBT", "dbt")

    case System.cmd(dbt, args ++ ["--project-dir", project_dir], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise "dbt #{Enum.join(args, " ")} exited with #{status}:\n#{out}"
    end
  end

  @doc "unique_id => relation_name for every built model in the current manifest."
  def relations(project_dir) do
    {:ok, project} = Project.load(Loader.Manifest, project_dir: project_dir)

    for node <- Project.nodes(project),
        node.resource_type == :model,
        node.config.materialized != :ephemeral,
        into: %{},
        do: {node.unique_id, node.relation_name}
  end

  @checksum "select count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from ~s t"

  @doc "Compares each model's rows in the two targets; returns the differences."
  def compare(adapter, conn, dbt_relations, bard_relations) do
    for {id, dbt_name} <- Enum.sort(dbt_relations),
        bard_name = Map.fetch!(bard_relations, id),
        {:ok, dbt_rel} = Relation.parse(dbt_name),
        {:ok, bard_rel} = Relation.parse(bard_name),
        dbt_sum = checksum(adapter, conn, dbt_rel),
        bard_sum = checksum(adapter, conn, bard_rel),
        dbt_sum != bard_sum do
      %{model: id, dbt: dbt_sum, bard: bard_sum}
    end
  end

  defp checksum(adapter, conn, relation) do
    sql = :io_lib.format(@checksum, [Relation.to_sql(relation)]) |> IO.iodata_to_binary()

    case adapter.query(conn, sql) do
      {:ok, [[count, md5]]} -> {count, md5}
      {:error, message} -> {:error, message}
    end
  end
end
