defmodule Bard.CLI.CompileTest do
  use ExUnit.Case, async: true

  alias Bard.CLI
  alias Bard.Test.MiniProject

  @profiles """
  mini:
    target: dev
    outputs:
      dev: {type: postgres, host: localhost, user: u, dbname: db, schema: dev, threads: 1}
  """

  defp project(models) do
    MiniProject.write(Map.put(models, "profiles.yml", @profiles))
  end

  describe "parse_vars/1" do
    test "reads YAML or JSON, like dbt --vars" do
      assert CLI.parse_vars(nil) == {:ok, %{}}
      assert CLI.parse_vars(~s({"a": 1})) == {:ok, %{"a" => 1}}
      assert CLI.parse_vars("a: x") == {:ok, %{"a" => "x"}}
      assert {:error, {:invalid_vars, "[1, 2]"}} = CLI.parse_vars("[1, 2]")
    end
  end

  describe "compile --offline" do
    test "writes each model's SQL under bard_target/compiled" do
      dir =
        project(%{
          "models/a.sql" => "select {{ var('n', 1) }}",
          "models/b.sql" => "select * from {{ ref('a') }}"
        })

      lines = fn -> Process.get(:lines, []) end
      print = fn line -> Process.put(:lines, lines.() ++ [line]) end

      assert {:ok, summary} =
               CLI.Compile.run([project_dir: dir, offline: true, vars: %{"n" => 2}], print)

      assert summary.models == 2
      assert summary.by_dbt == []
      assert File.read!(Path.join(summary.compiled_dir, "mini/models/a.sql")) == "select 2"

      assert File.read!(Path.join(summary.compiled_dir, "mini/models/b.sql")) ==
               ~s(select * from "db"."dev"."a")

      assert [line] = lines.()
      assert line =~ "Compiled 2 models on mini.dev"
    end

    test "errors come back as diagnostics, formatted with their codes" do
      dir = project(%{"models/a.sql" => "select {{ ref('nope') }}"})

      assert {:error, {:diagnostics, _} = reason} =
               CLI.Compile.run([project_dir: dir, offline: true], fn _ -> :ok end)

      message = CLI.format_error(reason)
      assert message =~ "models/a.sql: error BARD301: ref('nope') not found"
      assert message =~ "Compilation failed with 1 error(s)."
    end
  end

  test "compile_project/4 without a connection parses for bard ls" do
    dir = project(%{"models/a.sql" => "select 1"})
    {:ok, target} = Bard.Profile.load(dir)

    {:ok, project} = CLI.compile_project(dir, target, nil, compile: false, cache: false)
    assert project.nodes["model.mini.a"].compiled_code == nil
    assert project.graph
  end
end
