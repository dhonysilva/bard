defmodule Bard.RunResultsTest do
  use ExUnit.Case, async: true

  alias Bard.Config
  alias Bard.Node
  alias Bard.Project
  alias Bard.RunResults

  @moduletag :tmp_dir

  test "writes dbt's run_results format", %{tmp_dir: dir} do
    nodes =
      for id <- ~w(a b c), into: %{} do
        {id,
         %Node{
           unique_id: id,
           resource_type: :model,
           name: id,
           package: "p",
           relation_name: ~s("db"."s"."#{id}"),
           compiled_code: "select 1",
           config: %Config{materialized: :table}
         }}
      end

    results = %{
      "a" => {:success, %{attempts: 1, duration_ms: 1500, rows_affected: 99}},
      "b" => {:error, "ERROR 42P01 relation does not exist"},
      "c" => {:skipped, "b"}
    }

    path = Path.join(dir, "bard_target/run_results.json")
    run_results = RunResults.build(%Project{nodes: nodes, dbt_version: "1.10.0"}, results, 2000)
    :ok = RunResults.write(path, run_results)

    json = path |> File.read!() |> Jason.decode!()

    assert json["metadata"]["dbt_schema_version"] =~ "run-results/v6"
    assert json["elapsed_time"] == 2.0

    assert [
             %{
               "unique_id" => "a",
               "status" => "success",
               "execution_time" => 1.5,
               "adapter_response" => %{"rows_affected" => 99},
               "message" => "SELECT 99"
             },
             %{"unique_id" => "b", "status" => "error", "message" => "ERROR 42P01" <> _},
             %{"unique_id" => "c", "status" => "skipped"}
           ] = json["results"]
  end
end
