defmodule Bard.Loader.ManifestTest do
  use ExUnit.Case, async: true

  alias Bard.Config
  alias Bard.Node
  alias Bard.Project
  alias Bard.Loader.Manifest
  alias Bard.Test.Fixtures

  describe "load/1" do
    test "reads every supported node type and the sources" do
      {:ok, project} = Manifest.load(project_dir: Fixtures.jaffle_shop_dir())

      counts = project |> Project.nodes() |> Enum.frequencies_by(& &1.resource_type)

      assert counts == %{seed: 3, source: 1, model: 6, test: 4}
      assert project.name == "jaffle_shop"
      assert project.schema_version == "v12"
      assert project.dbt_version == "1.10.0"
      assert project.root == Fixtures.jaffle_shop_dir()
    end

    test "maps a model into Bard's own structs" do
      {:ok, project} = Manifest.load(project_dir: Fixtures.jaffle_shop_dir())
      {:ok, orders} = Project.fetch_node(project, "model.jaffle_shop.orders")

      assert %Node{
               resource_type: :model,
               name: "orders",
               package: "jaffle_shop",
               fqn: ["jaffle_shop", "marts", "orders"],
               original_file_path: "models/marts/orders.sql",
               config: %Config{materialized: :table, tags: ["marts", "daily"], enabled: true}
             } = orders

      assert orders.depends_on == [
               "model.jaffle_shop.stg_orders",
               "model.jaffle_shop.stg_payments"
             ]

      assert is_binary(orders.checksum)
      # Unknown config keys are kept, not dropped.
      assert orders.config.extra["on_schema_change"] == "ignore"
    end

    test "maps a source" do
      {:ok, project} = Manifest.load(project_dir: Fixtures.jaffle_shop_dir())
      {:ok, source} = Project.fetch_node(project, "source.jaffle_shop.ecom.raw_stores")

      assert source.resource_type == :source
      assert source.source_name == "ecom"
      assert source.name == "raw_stores"
      assert source.depends_on == []
    end

    test "reports a missing manifest with its path" do
      assert {:error, {:manifest_not_found, path}} =
               Manifest.load(project_dir: "/no/such/project")

      assert path == "/no/such/project/target/manifest.json"
    end

    test "requires a project dir or manifest path" do
      assert {:error, :missing_project_dir} = Manifest.load([])
    end
  end

  describe "from_map/2" do
    test "refuses manifest versions it does not know" do
      manifest = %{
        "metadata" => %{
          "dbt_schema_version" => "https://schemas.getdbt.com/dbt/manifest/v99.json"
        }
      }

      assert {:error, {:unsupported_manifest_version, "v99", supported}} =
               Manifest.from_map(manifest)

      assert "v12" in supported
    end

    test "keeps custom materializations as strings" do
      manifest = %{
        "metadata" => %{
          "dbt_schema_version" => "https://schemas.getdbt.com/dbt/manifest/v12.json"
        },
        "nodes" => %{
          "model.p.m" => %{
            "unique_id" => "model.p.m",
            "resource_type" => "model",
            "name" => "m",
            "package_name" => "p",
            "config" => %{"materialized" => "my_custom_mat"}
          },
          "analysis.p.a" => %{"unique_id" => "analysis.p.a", "resource_type" => "analysis"}
        }
      }

      assert {:ok, project} = Manifest.from_map(manifest)
      # Analyses are skipped in Phase 1.
      assert Map.keys(project.nodes) == ["model.p.m"]
      assert project.nodes["model.p.m"].config.materialized == "my_custom_mat"
    end
  end
end
