defmodule Bard.BuildTest do
  use ExUnit.Case, async: true

  alias Bard.Build
  alias Bard.Config
  alias Bard.Graph
  alias Bard.Node
  alias Bard.Project

  alias Bard.Test.FakeAdapter

  @moduletag :capture_log

  # stg ──► eph (ephemeral) ──► mart other (in another schema)
  setup do
    nodes =
      [
        model("stg", :view, []),
        model("eph", :ephemeral, ["stg"]),
        model("mart", :table, ["eph"]),
        model("other", :table, [], "finance")
      ]
      |> Map.new(&{&1.unique_id, &1})

    {:ok, graph} = Graph.build(nodes)

    {:ok, conn} =
      FakeAdapter.connect(%{existing: %{"marts.stg" => %{type: :view, columns: ["id"]}}})

    %{project: %Project{nodes: nodes, graph: graph}, conn: conn, all: Map.keys(nodes)}
  end

  defp model(name, materialized, parents, schema \\ "marts") do
    %Node{
      unique_id: name,
      resource_type: :model,
      name: name,
      package: "p",
      depends_on: parents,
      relation_name: if(materialized != :ephemeral, do: ~s("db"."#{schema}"."#{name}")),
      compiled_code: "select 1 as id",
      config: %Config{materialized: materialized}
    }
  end

  test "builds models in order and leaves ephemeral models out of the results", ctx do
    assert {:ok, results} = Build.run(ctx.project, ctx.all, FakeAdapter, ctx.conn, threads: 1)

    assert results |> Map.keys() |> Enum.sort() == ["mart", "other", "stg"]
    assert Enum.all?(results, &match?({_, {:success, _}}, &1))

    statements = FakeAdapter.statements(ctx.conn)

    stg_done =
      Enum.find_index(
        statements,
        &(&1 =~ ~s(drop view if exists "db"."marts"."stg__bard_backup"))
      )

    mart_created = Enum.find_index(statements, &(&1 =~ ~s(create table "db"."marts"."mart")))
    assert stg_done < mart_created, "mart must wait for stg through the ephemeral model"
  end

  test "creates each schema once, before any model runs", ctx do
    {:ok, _} = Build.run(ctx.project, ctx.all, FakeAdapter, ctx.conn)
    assert FakeAdapter.schemas(ctx.conn) == MapSet.new(["marts", "finance"])
  end

  test "a failure skips descendants through an ephemeral model", ctx do
    {:ok, conn} = FakeAdapter.connect(%{fail_on: ~r/"stg"/})
    {:ok, results} = Build.run(ctx.project, ctx.all, FakeAdapter, conn)

    assert {:error, :fake_failure} = results["stg"]
    assert results["mart"] == {:skipped, "stg"}
    assert {:success, _} = results["other"]
  end

  test "refuses to run models without compiled SQL", ctx do
    mart = %{ctx.project.nodes["mart"] | compiled_code: nil}
    project = %{ctx.project | nodes: Map.put(ctx.project.nodes, "mart", mart)}

    assert Build.run(project, ctx.all, FakeAdapter, ctx.conn) ==
             {:error, {:not_compiled, ["mart"]}}

    assert FakeAdapter.statements(ctx.conn) == []
  end
end
