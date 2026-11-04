defmodule Bard.Meta do
  @moduledoc """
  Stores a compiled project in the warehouse, in the `bard_meta` schema, so
  the project can be queried with SQL (and, from Phase 6, compared between
  runs for state-aware builds):

      select unique_id, materialized, relation_name
      from bard_meta.nodes
      where 'finance' = any(select jsonb_array_elements_text(tags));

      -- everything downstream of stg_orders
      with recursive down as (
        select child from bard_meta.edges where parent = 'model.shop.stg_orders'
        union
        select e.child from bard_meta.edges e join down d on e.parent = d.child
      )
      select * from down;

  Tables:

    * `bard_meta.nodes` - one row per node: ids, names, relation,
      materialization, tags, config, checksum, raw and compiled SQL and
      who compiled it (`bard` or `dbt`)
    * `bard_meta.edges` - `parent` -> `child`, one row per dependency
    * `bard_meta.diagnostics` - the compiler's warnings

  `write/3` replaces all rows in one transaction, so readers never see a
  half-written project. Rows are sent as arrays (`unnest`), one statement
  per table, whatever the project size.
  """

  use Boundary, top_level?: true, deps: [Bard, Bard.Adapter], exports: []

  alias Bard.{Node, Project}

  @schema "bard_meta"

  @ddl [
    "create schema if not exists #{@schema}",
    """
    create table if not exists #{@schema}.nodes (
      unique_id text primary key,
      resource_type text not null,
      name text not null,
      package text,
      fqn jsonb,
      original_file_path text,
      relation_name text,
      materialized text,
      tags jsonb,
      config jsonb,
      checksum text,
      raw_code text,
      compiled_code text,
      compiled_by text,
      written_at timestamptz not null default now()
    )
    """,
    """
    create table if not exists #{@schema}.edges (
      parent text not null,
      child text not null,
      primary key (parent, child)
    )
    """,
    """
    create table if not exists #{@schema}.diagnostics (
      code text not null,
      severity text not null,
      message text not null,
      file text,
      line integer,
      unique_id text
    )
    """
  ]

  @insert_nodes """
  insert into #{@schema}.nodes (unique_id, resource_type, name, package, fqn,
    original_file_path, relation_name, materialized, tags, config, checksum,
    raw_code, compiled_code, compiled_by)
  select u, rt, n, p, f::jsonb, ofp, rn, m, t::jsonb, c::jsonb, cs, rc, cc, cb
  from unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[],
              $7::text[], $8::text[], $9::text[], $10::text[], $11::text[], $12::text[],
              $13::text[], $14::text[])
    as x(u, rt, n, p, f, ofp, rn, m, t, c, cs, rc, cc, cb)
  """

  @insert_edges """
  insert into #{@schema}.edges (parent, child)
  select * from unnest($1::text[], $2::text[])
  """

  @insert_diagnostics """
  insert into #{@schema}.diagnostics (code, severity, message, file, line, unique_id)
  select * from unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::int[], $6::text[])
  """

  @doc "Replaces the stored project with `project`."
  @spec write(module(), term(), Project.t()) :: :ok | {:error, term()}
  def write(adapter, conn, %Project{} = project) do
    statements =
      @ddl ++
        [
          "delete from #{@schema}.edges",
          "delete from #{@schema}.nodes",
          "delete from #{@schema}.diagnostics",
          {@insert_nodes, node_columns(project)},
          {@insert_edges, edge_columns(project)},
          {@insert_diagnostics, diagnostic_columns(project.diagnostics)}
        ]

    case adapter.transaction(conn, statements) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  # Column-wise lists, one per `$n` parameter of @insert_nodes.
  def node_columns(project) do
    nodes = project |> Project.nodes() |> Enum.sort_by(& &1.unique_id)

    [
      & &1.unique_id,
      &to_string(&1.resource_type),
      & &1.name,
      & &1.package,
      &Jason.encode!(&1.fqn),
      & &1.original_file_path,
      & &1.relation_name,
      &(&1.config.materialized && to_string(&1.config.materialized)),
      &Jason.encode!(Node.tags(&1)),
      &Jason.encode!(config_json(&1.config)),
      & &1.checksum,
      & &1.raw_code,
      & &1.compiled_code,
      &(&1.compiled_by && to_string(&1.compiled_by))
    ]
    |> Enum.map(&Enum.map(nodes, &1))
  end

  defp config_json(config) do
    config
    |> Map.from_struct()
    |> Map.delete(:extra)
    |> Map.merge(config.extra)
    |> Map.update!(:materialized, &(&1 && to_string(&1)))
  end

  @doc false
  def edge_columns(project) do
    edges =
      for node <- Project.nodes(project),
          parent <- Enum.uniq(node.depends_on),
          do: {parent, node.unique_id}

    edges = Enum.sort(edges)
    [Enum.map(edges, &elem(&1, 0)), Enum.map(edges, &elem(&1, 1))]
  end

  @doc false
  def diagnostic_columns(diagnostics) do
    [
      & &1.code,
      &to_string(&1.severity),
      & &1.message,
      & &1.file,
      & &1.line,
      & &1.unique_id
    ]
    |> Enum.map(&Enum.map(diagnostics, &1))
  end
end
