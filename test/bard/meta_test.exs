defmodule Bard.MetaTest do
  use ExUnit.Case, async: true

  alias Bard.Adapter.Postgres
  alias Bard.Meta
  alias Bard.Test.FakeAdapter
  alias Bard.Test.MiniProject

  defp project do
    dir =
      MiniProject.write(%{
        "models/a.sql" => "{{ config(materialized='table', tags=['x']) }}select 1",
        "models/b.sql" => "select * from {{ ref('a') }}",
        "models/c.sql" => "{{ config(owner='me') }}select 1"
      })

    {:ok, project} =
      Bard.Project.load(Bard.Loader.Files,
        project_dir: dir,
        target: MiniProject.target(),
        cache: false
      )

    project
  end

  test "one transaction: tables, deletes, then one insert per table" do
    {:ok, conn} = FakeAdapter.connect(%{})
    assert :ok = Meta.write(FakeAdapter, conn, project())

    statements = FakeAdapter.statements(conn)
    {inserts, plain} = Enum.split_with(statements, &is_tuple/1)

    assert Enum.any?(plain, &(&1 =~ "create table if not exists bard_meta.nodes"))
    assert Enum.count(plain, &String.starts_with?(&1, "delete from bard_meta.")) == 3

    [{nodes_sql, node_params}, {edges_sql, edge_params}, {diag_sql, diag_params}] = inserts
    assert nodes_sql =~ "insert into bard_meta.nodes"
    assert edges_sql =~ "insert into bard_meta.edges"
    assert diag_sql =~ "insert into bard_meta.diagnostics"

    # 14 columns, one value per node in each.
    assert length(node_params) == 14
    assert hd(node_params) == ["model.mini.a", "model.mini.b", "model.mini.c"]
    assert edge_params == [["model.mini.a"], ["model.mini.b"]]
    assert [["BARD102"] | _] = diag_params
  end

  @tag :postgres
  test "writes rows Postgres can query" do
    target = %{
      host: System.get_env("BARD_TEST_PG_HOST", "localhost"),
      port: String.to_integer(System.get_env("BARD_TEST_PG_PORT", "5432")),
      user: System.get_env("BARD_TEST_PG_USER", "postgres"),
      password: System.get_env("BARD_TEST_PG_PASSWORD", "postgres"),
      dbname: System.get_env("BARD_TEST_PG_DB", "postgres"),
      threads: 1
    }

    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, conn} = Postgres.connect(target)

    try do
      assert :ok = Meta.write(Postgres, conn, project())

      assert {:ok, [["model.mini.a", "table", "bard", ["x"]]]} =
               Postgres.query(
                 conn,
                 "select unique_id, materialized, compiled_by, tags from bard_meta.nodes where $1 = any(select jsonb_array_elements_text(tags))",
                 ["x"]
               )

      assert {:ok, [[1]]} = Postgres.query(conn, "select count(*)::int from bard_meta.edges", [])

      # A second write replaces, not appends.
      assert :ok = Meta.write(Postgres, conn, project())
      assert {:ok, [[3]]} = Postgres.query(conn, "select count(*)::int from bard_meta.nodes")
    after
      Postgres.disconnect(conn)
    end
  end
end
