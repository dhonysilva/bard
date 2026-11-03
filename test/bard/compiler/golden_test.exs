defmodule Bard.Compiler.GoldenTest do
  @moduledoc """
  Bard's compiler against dbt's own output for `test/fixtures/shop`, with no
  dbt and no database: the expected values were captured from dbt-core 1.10
  (see `test/fixtures/shop/expected/README.md`).

  To refresh them, run in the fixture folder

      dbt compile && python3 extract.py target/manifest.json expected/dbt_compile_fresh.json
      dbt seed && dbt run && dbt compile && python3 extract.py target/manifest.json expected/dbt_compile_built.json

  where `extract.py` keeps, for each model, seed and source, the fields this
  test compares.
  """

  use ExUnit.Case, async: true

  alias Bard.Compiler

  @fixture "test/fixtures/shop"

  @target %{
    name: "dev",
    profile: "shop",
    type: "postgres",
    host: "localhost",
    port: 5432,
    user: "postgres",
    dbname: "bard",
    schema: "shop_dev",
    threads: 4
  }

  defp expected(file) do
    Path.join([@fixture, "expected", file]) |> File.read!() |> Jason.decode!()
  end

  defp compile(relation_type) do
    {:ok, project} =
      Compiler.load(
        project_dir: @fixture,
        target: @target,
        relation_type: relation_type,
        cache: false
      )

    project
  end

  # The fields extract.py keeps, from a Bard node.
  defp actual(node) do
    %{
      "resource_type" => to_string(node.resource_type),
      "relation_name" => node.relation_name,
      "depends_on" => Enum.sort(node.depends_on),
      "materialized" => node.config.materialized && to_string(node.config.materialized),
      "schema" => node.config.schema,
      "alias" => node.config.alias,
      "tags" => Enum.sort(node.config.tags),
      "fqn" => node.fqn,
      "compiled_code" => node.compiled_code
    }
  end

  for {name, file, exists} <- [
        {"fresh", "dbt_compile_fresh.json", nil},
        {"built", "dbt_compile_built.json", :table}
      ] do
    describe "#{name} warehouse" do
      setup do
        System.delete_env("SHOP_REGION")
        project = compile(fn _relation -> unquote(exists) end)
        %{project: project, expected: expected(unquote(file))}
      end

      test "the same nodes as dbt", %{project: project, expected: expected} do
        assert project.nodes |> Map.keys() |> Enum.sort() == expected |> Map.keys() |> Enum.sort()
      end

      test "every field matches dbt", %{project: project, expected: expected} do
        for {id, want} <- expected do
          got = actual(project.nodes[id])

          for {field, value} <- want do
            assert {id, field, got[field]} == {id, field, value}
          end
        end
      end

      test "no diagnostics", %{project: project} do
        assert project.diagnostics == []
      end
    end
  end
end
