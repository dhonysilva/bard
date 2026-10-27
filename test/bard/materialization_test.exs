defmodule Bard.MaterializationTest do
  use ExUnit.Case, async: true

  alias Bard.Config
  alias Bard.Materialization
  alias Bard.Node

  defp model(materialized, extra \\ %{}) do
    %Node{
      unique_id: "model.p.orders",
      resource_type: :model,
      name: "orders",
      package: "p",
      relation_name: ~s("db"."marts"."orders"),
      compiled_code: "select 1 as id;\n",
      config: %Config{materialized: materialized, extra: extra}
    }
  end

  describe "view and table" do
    test "create directly when nothing exists" do
      assert Materialization.plan(model(:view), nil) ==
               {:run, [~s(create view "db"."marts"."orders" as (\nselect 1 as id\n\))]}

      assert {:run, [~s(create table "db"."marts"."orders" as) <> _]} =
               Materialization.plan(model(:table), nil)
    end

    test "swap a new relation into place over an existing one" do
      {:run, statements} = Materialization.plan(model(:table), %{type: :view, columns: ["id"]})

      assert statements == [
               ~s(create table "db"."marts"."orders__bard_tmp" as (\nselect 1 as id\n\)),
               ~s(alter view "db"."marts"."orders" rename to "orders__bard_backup"),
               ~s(alter table "db"."marts"."orders__bard_tmp" rename to "orders"),
               ~s(drop view if exists "db"."marts"."orders__bard_backup" cascade)
             ]
    end
  end

  describe "incremental" do
    test "builds a table on the first run" do
      assert {:run, [~s(create table "db"."marts"."orders" as) <> _]} =
               Materialization.plan(model(:incremental, %{"unique_key" => "id"}), nil)
    end

    test "deletes matching keys, then inserts the target's columns" do
      existing = %{type: :table, columns: ["id", "amount"]}

      {:run, statements} =
        Materialization.plan(model(:incremental, %{"unique_key" => "id"}), existing)

      assert statements == [
               ~s(create temporary table "orders__bard_tmp" on commit drop as (\nselect 1 as id\n\)),
               ~s(delete from "db"."marts"."orders" using "orders__bard_tmp" where "db"."marts"."orders"."id" = "orders__bard_tmp"."id"),
               ~s(insert into "db"."marts"."orders" ("id", "amount"\) select "id", "amount" from "orders__bard_tmp")
             ]
    end

    test "supports composite keys and plain appends" do
      existing = %{type: :table, columns: ["a"]}

      {:run, [_, delete, _]} =
        Materialization.plan(model(:incremental, %{"unique_key" => ["a", "b"]}), existing)

      assert delete =~ ~s("orders"."a" = "orders__bard_tmp"."a" and "db"."marts"."orders"."b")

      assert {:run, [_create, "insert into" <> _]} =
               Materialization.plan(model(:incremental), existing)
    end

    test "rebuilds as a table on full refresh or over a view" do
      table = %{type: :table, columns: ["id"]}
      view = %{type: :view, columns: ["id"]}

      assert {:run, [~s(create table "db"."marts"."orders__bard_tmp") <> _ | _]} =
               Materialization.plan(model(:incremental), table, full_refresh: true)

      assert {:run, [_, "alter view" <> _, _, "drop view" <> _]} =
               Materialization.plan(model(:incremental), view)
    end
  end

  test "ephemeral models need nothing" do
    assert Materialization.plan(model(:ephemeral), nil) == :skip
  end

  test "errors" do
    assert Materialization.plan(%{model(:table) | compiled_code: nil}, nil) ==
             {:error, :not_compiled}

    assert Materialization.plan(model("my_custom"), nil) ==
             {:error, {:unsupported_materialization, "my_custom"}}
  end
end
