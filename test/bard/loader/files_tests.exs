defmodule Bard.Loader.FilesTest do
  use ExUnit.Case, async: true

  alias Bard.Test.MiniProject

  test "loads through Bard.Project, with a graph" do
    dir =
      MiniProject.write(%{
        "models/a.sql" => "select 1",
        "models/b.sql" => "select * from {{ ref('a') }}"
      })

    {:ok, project} =
      Bard.Project.load(Bard.Loader.Files,
        project_dir: dir,
        target: MiniProject.target(),
        cache: false
      )

    assert Bard.Graph.parents(project.graph, "model.mini.b") == ["model.mini.a"]
  end

  test "fallback_manifest: dbt's compiled SQL for what Bard cannot compile" do
    dir =
      MiniProject.write(%{
        "models/a.sql" => "{{ dbt_utils.star(ref('b')) }}",
        "models/b.sql" => "select 1"
      })

    manifest = %{
      "metadata" => %{"dbt_schema_version" => "https://schemas.getdbt.com/dbt/manifest/v12.json"},
      "nodes" => %{
        "model.mini.a" => %{
          "unique_id" => "model.mini.a",
          "resource_type" => "model",
          "name" => "a",
          "package_name" => "mini",
          "compiled_code" => ~s(select "x" from "db"."dev"."b"),
          "depends_on" => %{"nodes" => ["model.mini.b"]}
        }
      }
    }

    path = Path.join(dir, "manifest.json")
    File.write!(path, Jason.encode!(manifest))

    {:ok, project} =
      Bard.Project.load(Bard.Loader.Files,
        project_dir: dir,
        target: MiniProject.target(),
        fallback_manifest: path,
        cache: false
      )

    a = project.nodes["model.mini.a"]
    assert a.compiled_by == :dbt
    assert a.compiled_code == ~s(select "x" from "db"."dev"."b")
    assert a.depends_on == ["model.mini.b"]
    assert [%{code: "BARD401"}] = project.diagnostics
  end
end
