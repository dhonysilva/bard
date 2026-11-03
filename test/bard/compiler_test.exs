defmodule Bard.CompilerTest do
  use ExUnit.Case, async: true

  alias Bard.Compiler
  alias Bard.Test.MiniProject

  defp load(files, opts \\ []) do
    dir = MiniProject.write(files)
    Compiler.load([project_dir: dir, target: MiniProject.target(), cache: false] ++ opts)
  end

  defp codes({:error, {:diagnostics, diags}}), do: Enum.map(diags, & &1.code)

  test "refs, sources, vars and macros" do
    {:ok, project} =
      load(%{
        "macros/m.sql" => "{% macro twice(x) %}{{ x }} * 2{% endmacro %}",
        "models/src.yml" => """
        version: 2
        sources:
          - name: raw
            tables: [{name: events}]
        """,
        "models/a.sql" => "select {{ twice('n') }} as n from {{ source('raw', 'events') }}",
        "models/b.sql" => "select * from {{ ref('a') }} where n > {{ var('min', 1) }}"
      })

    a = project.nodes["model.mini.a"]
    b = project.nodes["model.mini.b"]

    assert a.compiled_code == ~s(select n * 2 as n from "db"."raw"."events")
    assert a.depends_on == ["source.mini.raw.events"]
    assert b.compiled_code == ~s(select * from "db"."dev"."a" where n > 1)
    assert b.depends_on == ["model.mini.a"]
    assert b.compiled_by == :bard
  end

  test "disabled models are left out" do
    {:ok, project} = load(%{"models/a.sql" => "{{ config(enabled=false) }} select 1"})
    refute Map.has_key?(project.nodes, "model.mini.a")
  end

  test "config() and config.get" do
    {:ok, project} =
      load(%{
        "models/a.sql" => """
        {{ config(materialized='table', tags=['x']) }}select '{{ config.get('materialized') }}'\
        """
      })

    node = project.nodes["model.mini.a"]
    assert node.config.materialized == :table
    assert node.config.tags == ["x"]
    assert node.compiled_code == "select 'table'"
  end

  test "is_incremental() follows the warehouse and full refresh" do
    files = %{
      "models/inc.sql" => """
      {{ config(materialized='incremental') }}select 1{% if is_incremental() %} where new{% endif %}\
      """
    }

    sql = fn opts ->
      {:ok, project} = load(files, opts)
      project.nodes["model.mini.inc"].compiled_code
    end

    assert sql.([]) == "select 1"
    assert sql.(relation_type: fn _ -> :table end) == "select 1 where new"
    assert sql.(relation_type: fn _ -> :view end) == "select 1"
    assert sql.(relation_type: fn _ -> :table end, full_refresh: true) == "select 1"
  end

  test "errors carry codes, files and lines" do
    assert {:error, {:diagnostics, [diag]}} =
             load(%{"models/a.sql" => "select\n{{ ref('nope') }}"})

    assert diag.code == "BARD301"
    assert diag.file == "models/a.sql"
    assert diag.unique_id == "model.mini.a"

    assert codes(load(%{"models/a.sql" => "{{ source('x', 'y') }}"})) == ["BARD302"]
    assert codes(load(%{"models/a.sql" => "{% call m() %}{% endcall %}"})) == ["BARD201"]
    assert codes(load(%{"models/a.sql" => "{{ var('missing') }}"})) == ["BARD202"]

    assert codes(load(%{"models/a.sql" => "select 1", "models/x/a.sql" => "select 2"})) ==
             ["BARD303"]

    assert {:error, {:diagnostics, [line]}} = load(%{"models/a.sql" => "a\nb\n{{ adapter.x() }}"})
    assert line.line == 3
  end

  test "warnings do not fail the load" do
    {:ok, project} = load(%{"models/a.sql" => "{{ config(owner_team='x') }}select 1"})
    assert [%{code: "BARD102"}] = project.diagnostics
  end

  test "fallback: dbt's SQL for nodes Bard cannot compile" do
    dbt = %Bard.Node{
      unique_id: "model.mini.a",
      resource_type: :model,
      name: "a",
      package: "mini",
      compiled_code: "select 42",
      depends_on: []
    }

    {:ok, project} =
      load(%{"models/a.sql" => "{{ run_query('x') }}"}, fallback: %{"model.mini.a" => dbt})

    node = project.nodes["model.mini.a"]
    assert node.compiled_code == "select 42"
    assert node.compiled_by == :dbt
    assert [%{code: "BARD401"} = warning] = project.diagnostics
    assert warning.message =~ "run_query"
  end

  test "compile: false only parses" do
    {:ok, project} = load(%{"models/a.sql" => "select 1"}, compile: false)
    assert project.nodes["model.mini.a"].compiled_code == nil
  end

  describe "parse cache" do
    test "reuses results for unchanged files and notices env var changes" do
      dir =
        MiniProject.write(%{"models/a.sql" => "select '{{ env_var('BARD_CACHE_TEST', 'x') }}'"})

      opts = [project_dir: dir, target: MiniProject.target()]

      {:ok, _} = Compiler.load(opts)
      assert File.exists?(Bard.Compiler.Cache.path(dir))

      {:ok, project} = Compiler.load(opts)
      assert project.nodes["model.mini.a"].compiled_code == "select 'x'"

      File.write!(Path.join(dir, "models/a.sql"), "select 2 from {{ ref('missing') }}")
      assert {:error, {:diagnostics, [%{code: "BARD301"}]}} = Compiler.load(opts)
    end
  end
end
