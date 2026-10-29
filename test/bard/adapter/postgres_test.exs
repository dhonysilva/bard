defmodule Bard.Adapter.PostgresTest do
  @moduledoc """
  Runs against a real Postgres. Excluded by default:

      docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:16
      mix test --only postgres

  Connection settings come from BARD_TEST_PG_HOST, _PORT, _USER, _PASSWORD and
  _DB (defaults: localhost, 5432, postgres, postgres, postgres). Each test
  works in its own schema and drops it afterwards.
  """

  use ExUnit.Case, async: false

  alias Bard.Config
  alias Bard.Materialization
  alias Bard.Node
  alias Bard.Relation

  alias Bard.Adapter.Postgres

  @moduletag :postgres

  setup do
    target = %{
      host: System.get_env("BARD_TEST_PG_HOST", "localhost"),
      port: String.to_integer(System.get_env("BARD_TEST_PG_PORT", "5432")),
      user: System.get_env("BARD_TEST_PG_USER", "postgres"),
      password: System.get_env("BARD_TEST_PG_PASSWORD", "postgres"),
      dbname: System.get_env("BARD_TEST_PG_DB", "postgres"),
      threads: 2
    }

    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, conn} = Postgres.connect(target)
    schema = "bard_test_#{System.unique_integer([:positive])}"
    :ok = Postgres.ensure_schema(conn, %Relation{schema: schema, identifier: "x"})

    on_exit(fn ->
      {:ok, cleanup} = Postgres.connect(target)
      Postgres.query(cleanup, "drop schema #{schema} cascade")
      Postgres.disconnect(cleanup)
    end)

    %{conn: conn, schema: schema}
  end

  defp model(schema, materialized, sql, extra \\ %{}) do
    %Node{
      unique_id: "model.p.m",
      resource_type: :model,
      name: "m",
      package: "p",
      relation_name: ~s("#{schema}"."m"),
      compiled_code: sql,
      config: %Config{materialized: materialized, extra: extra}
    }
  end

  # describe -> plan -> transaction, exactly what Bard.Build does.
  defp build(conn, node, opts \\ []) do
    {:ok, relation} = Relation.parse(node.relation_name)
    {:ok, existing} = Postgres.describe(conn, relation)
    {:run, statements} = Materialization.plan(node, existing, opts)
    Postgres.transaction(conn, statements)
  end

  defp rows(conn, schema), do: Postgres.query(conn, ~s(select * from "#{schema}"."m" order by 1))

  test "describe reports type and columns, or nil", %{conn: conn, schema: schema} do
    relation = %Relation{schema: schema, identifier: "m"}
    assert Postgres.describe(conn, relation) == {:ok, nil}

    {:ok, _} = build(conn, model(schema, :view, "select 1 as id, 'a' as name"))
    assert Postgres.describe(conn, relation) == {:ok, %{type: :view, columns: ["id", "name"]}}
  end

  test "a view is rebuilt even when its columns change", %{conn: conn, schema: schema} do
    {:ok, _} = build(conn, model(schema, :view, "select 1 as id, 'a' as name"))
    # `create or replace view` would fail here: a column is removed.
    {:ok, _} = build(conn, model(schema, :view, "select 2 as id"))

    assert rows(conn, schema) == {:ok, [[2]]}
  end

  test "a table replaces a view and reports rows", %{conn: conn, schema: schema} do
    {:ok, _} = build(conn, model(schema, :view, "select 1 as id"))

    assert {:ok, %{rows_affected: 3}} =
             build(conn, model(schema, :table, "select generate_series(1, 3) as id"))

    {:ok, info} = Postgres.describe(conn, %Relation{schema: schema, identifier: "m"})
    assert info.type == :table
  end

  test "a failed build leaves the old relation untouched", %{conn: conn, schema: schema} do
    {:ok, _} = build(conn, model(schema, :table, "select 1 as id"))
    assert {:error, message} = build(conn, model(schema, :table, "select 1 / 0 as id"))
    assert message =~ "division by zero"

    assert rows(conn, schema) == {:ok, [[1]]}
  end

  test "incremental merges on unique_key", %{conn: conn, schema: schema} do
    first = "select * from (values (1, 'old'), (2, 'old')) as t(id, status)"
    second = "select * from (values (2, 'new'), (3, 'new')) as t(id, status)"
    key = %{"unique_key" => "id"}

    {:ok, %{rows_affected: 2}} = build(conn, model(schema, :incremental, first, key))
    {:ok, %{rows_affected: 2}} = build(conn, model(schema, :incremental, second, key))

    assert rows(conn, schema) == {:ok, [[1, "old"], [2, "new"], [3, "new"]]}

    {:ok, _} = build(conn, model(schema, :incremental, second, key), full_refresh: true)
    assert rows(conn, schema) == {:ok, [[2, "new"], [3, "new"]]}
  end
end
