defmodule Bard.Materialization do
  @moduledoc """
  Turns a compiled model into the SQL statements that build it.

  `plan/3` is a pure function: it reads the node and what already exists in
  the warehouse, and returns statements. It never connects to anything, so
  every materialization is tested without a database. `Bard.Build` runs the
  plan in a single transaction, which on Postgres makes DDL atomic too: if
  any statement fails, the old relation is left exactly as it was.

  ## Plans (Postgres)

    * `view` and `table` - with nothing in place, create the relation. Over an
      existing one, build `<name>__bard_tmp`, rename the old relation to
      `<name>__bard_backup`, rename the new one into place and drop the
      backup. This avoids `create or replace view`, which Postgres refuses
      when columns change. Like dbt on Postgres, dropping the backup cascades
      to views that depended on it.
    * `incremental` - with no table in place, with a view in place, or with
      `full_refresh: true`, build it as a table. Otherwise load the compiled
      SQL into a temporary table, delete target rows whose `unique_key`
      matches, and insert. Without a `unique_key` it only inserts. Only the
      target's existing columns are inserted (dbt's `on_schema_change:
      ignore`).
    * `ephemeral` - nothing to run: dbt inlines it as a CTE downstream.
  """

  use Boundary, top_level?: true, deps: [Bard, Bard.Adapter], exports: []

  alias Bard.Adapter
  alias Bard.Node
  alias Bard.Relation

  @type plan :: {:run, [String.t()]} | :skip | {:error, term()}

  @tmp "__bard_tmp"
  @backup "__bard_backup"

  @spec plan(Node.t(), Adapter.existing(), keyword()) :: plan()

  def plan(%Node{} = node, existing, opts \\ []) do
    case node.config.materialized do
      :ephemeral -> :skip
      :view -> with_target(node, &swap(&1, &2, :view, existing))
      :table -> with_target(node, &swap(&1, &2, :table, existing))
      :incremental -> with_target(node, &incremental(&1, &2, node, existing, opts))
      other -> {:error, {:unsupported_materialization, other}}
    end
  end

  defp with_target(%Node{compiled_code: nil}, _fun), do: {:error, :not_compiled}

  defp with_target(%Node{} = node, fun) do
    with {:ok, relation} <- Relation.parse(node.relation_name) do
      {:run, fun.(relation, clean(node.compiled_code))}
    end
  end

  defp swap(target, sql, kind, nil), do: [create(kind, target, sql)]

  defp swap(target, sql, kind, %{type: old_type}) do
    tmp = Relation.with_suffix(target, @tmp)
    backup = Relation.with_suffix(target, @backup)

    [
      create(kind, tmp, sql),
      "alter #{ddl(old_type)} #{Relation.to_sql(target)} rename to #{Relation.quoted_identifier(backup)}",
      "alter #{ddl(kind)} #{Relation.to_sql(tmp)} rename to #{Relation.quoted_identifier(target)}",
      "drop #{ddl(old_type)} if exists #{Relation.to_sql(backup)} cascade"
    ]
  end

  defp create(:view, relation, sql),
    do: "create view #{Relation.to_sql(relation)} as (\n#{sql}\n)"

  defp create(:table, relation, sql),
    do: "create table #{Relation.to_sql(relation)} as (\n#{sql}\n)"

  defp ddl(:view), do: "view"
  defp ddl(_table), do: "table"

  defp incremental(target, sql, node, existing, opts) do
    full_refresh? = Keyword.get(opts, :full_refresh, false)

    case existing do
      %{type: :table, columns: columns} when not full_refresh? ->
        merge(target, sql, columns, unique_key(node))

      _nothing_view_or_full_refresh ->
        swap(target, sql, :table, existing)
    end
  end

  defp merge(target, sql, columns, keys) do
    # Temporary tables live in their own schema, so the name stays unqualified.
    staging = Relation.quoted_identifier(Relation.with_suffix(target, @tmp))
    target_sql = Relation.to_sql(target)
    column_list = Enum.map_join(columns, ", ", &Relation.quote_ident/1)

    delete =
      case keys do
        [] ->
          []

        keys ->
          on = Enum.map_join(keys, " and ", &"#{target_sql}.#{q(&1)} = #{staging}.#{q(&1)}")
          ["delete from #{target_sql} using #{staging} where #{on}"]
      end

    ["create temporary table #{staging} on commit drop as (\n#{sql}\n)"] ++
      delete ++
      ["insert into #{target_sql} (#{column_list}) select #{column_list} from #{staging}"]
  end

  defp unique_key(%Node{config: config}) do
    case config.extra["unique_key"] do
      nil -> []
      key when is_binary(key) -> [key]
      keys when is_list(keys) -> keys
    end
  end

  defp q(column), do: Relation.quote_ident(column)

  # dbt's compiled SQL may end in a semicolon, which breaks `as ( ... )`.
  defp clean(sql), do: sql |> String.trim() |> String.trim_trailing(";") |> String.trim()
end
