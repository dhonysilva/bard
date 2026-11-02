defmodule Bard.Compiler.ConfigTest do
  use ExUnit.Case, async: true

  alias Bard.Compiler.Config

  @tree %{
    "shop" => %{
      "+materialized" => "view",
      "+tags" => ["all"],
      "marts" => %{
        "+materialized" => "table",
        "+tags" => "marts",
        "+meta" => %{"owner" => "data"},
        # dbt v1 style: no `+`
        "enabled" => true,
        "finance" => %{"+schema" => "finance", "+meta" => %{"pii" => false}}
      }
    }
  }

  describe "from_tree/2" do
    test "walks the fqn, more specific folders override" do
      config = Config.from_tree(@tree, ["shop", "marts", "finance", "revenue"])

      assert config["materialized"] == "table"
      assert config["schema"] == "finance"
      assert config["enabled"] == true
      assert config["tags"] == ["all", "marts"]
      assert config["meta"] == %{"owner" => "data", "pii" => false}
    end

    test "stops where the tree ends" do
      assert Config.from_tree(@tree, ["shop", "staging", "stg"]) == %{
               "materialized" => "view",
               "tags" => ["all"]
             }

      assert Config.from_tree(@tree, ["other_package", "x"]) == %{}
    end
  end

  test "merge/2 adds tags, merges meta, replaces the rest" do
    base = %{"tags" => ["a"], "meta" => %{"x" => 1}, "alias" => "old"}
    override = %{"tags" => ["b", "a"], "meta" => %{"y" => 2}, "alias" => "new"}

    assert Config.merge(base, override) == %{
             "tags" => ["a", "b"],
             "meta" => %{"x" => 1, "y" => 2},
             "alias" => "new"
           }
  end

  describe "validate/2" do
    test "builds a Bard.Config, keeping unknown keys with a warning" do
      {config, [warning]} =
        Config.validate(%{"materialized" => "table", "tags" => "one", "owner_team" => "x"},
          file: "models/a.sql"
        )

      assert config.materialized == :table
      assert config.tags == ["one"]
      assert config.extra == %{"owner_team" => "x"}
      assert warning.code == "BARD102"
      assert warning.severity == :warning
      assert warning.file == "models/a.sql"
    end

    test "a wrong type is an error" do
      {_config, [error]} = Config.validate(%{"enabled" => "yes"})
      assert error.code == "BARD101"
      assert error.message =~ "enabled"
    end
  end
end
