defmodule Bard.ParityTest do
  @moduledoc """
  Bard must select exactly what `dbt ls` selects.

  Needs dbt installed and a parsed dbt project:

      cd ../analytics_dbt && dbt parse
      BARD_PARITY_PROJECT=../analytics_dbt mix test --only parity

  Set `BARD_DBT` if the dbt executable is not on the PATH. Selectors are
  generated from the project itself: one per resource type, then `+m`,
  `m+` and `@m` for up to 20 models.
  """

  use ExUnit.Case, async: false

  alias Bard.Test.Parity

  @moduletag :parity
  @moduletag timeout: :infinity

  setup_all do
    dir =
      System.get_env("BARD_PARITY_PROJECT") ||
        raise "Set BARD_PARITY_PROJECT to a parsed dbt project to run parity tests."

    {:ok, project} = Bard.Project.load(Bard.Loader.Manifest, project_dir: Path.expand(dir))
    %{project: project}
  end

  test "selectors match dbt ls", %{project: project} do
    models =
      project.nodes
      |> Map.values()
      |> Enum.filter(&(&1.resource_type == :model))
      |> Enum.map(& &1.name)
      |> Enum.sort()
      |> Enum.take(20)

    selectors =
      [nil] ++
        Enum.map(~w(model seed snapshot test source), &"resource_type:#{&1}") ++
        Enum.flat_map(models, &["+#{&1}", "#{&1}+", "@#{&1}"])

    failures =
      for selector <- selectors,
          result = Parity.compare(project, select: selector),
          result != :ok,
          do: {selector || "(all)", result}

    assert failures == [], """
    Bard and dbt ls disagree on #{length(failures)} of #{length(selectors)} selectors:

    #{Enum.map_join(failures, "\n\n", fn {s, r} -> "#{s}: #{inspect(r, pretty: true)}" end)}
    """
  end
end
