defmodule Bard.Compiler.ProjectFileTest do
  use ExUnit.Case, async: true

  alias Bard.Compiler.ProjectFile
  alias Bard.Test.MiniProject

  @target MiniProject.target()

  test "reads paths, vars and config trees, rendering Jinja" do
    dir =
      MiniProject.write(%{}, """
      name: mini
      profile: mini
      model-paths: ["{{ 'transform' }}"]
      vars:
        a: 1
        mini: {b: 2}
      models:
        mini:
          +schema: "{{ target.name }}_x"
      """)

    {:ok, pf} = ProjectFile.load(dir, @target)

    assert pf.name == "mini"
    assert pf.model_paths == ["transform"]
    assert pf.seed_paths == ["seeds"]
    assert pf.models == %{"mini" => %{"+schema" => "dev_x"}}
    assert ProjectFile.vars(pf, %{"b" => 3}) == %{"a" => 1, "b" => 3}
    assert ProjectFile.vars(pf, %{}) == %{"a" => 1, "b" => 2}
  end

  test "error codes" do
    missing = Path.join(System.tmp_dir!(), "bard_nothing_here")
    assert {:error, [%{code: "BARD001"}]} = ProjectFile.load(missing, @target)

    assert {:error, [%{code: "BARD002"}]} =
             ProjectFile.load(MiniProject.write(%{}, "name: [unclosed"), @target)

    assert {:error, [%{code: "BARD003"}]} =
             ProjectFile.load(MiniProject.write(%{}, "profile: x\n"), @target)

    assert {:error, [%{code: "BARD004"}]} =
             ProjectFile.load(MiniProject.write(%{}, "name: x\nmodel-paths: models\n"), @target)
  end
end
