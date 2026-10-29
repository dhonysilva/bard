defmodule Bard.RunParityTest do
  @moduledoc """
  The Phase 2 gate: `bard run` builds the same data as `dbt run`.

  Needs dbt, a Postgres, and a dbt project whose profile has two targets
  pointing at different schemas of the same database:

      BARD_RUN_PARITY_PROJECT=../analytics_dbt \\
      BARD_RUN_PARITY_DBT_TARGET=dbt_ref BARD_RUN_PARITY_BARD_TARGET=bard_out \\
        mix test --only run_parity

  It seeds both targets, then does two rounds of: `dbt run` into the dbt
  target, `dbt compile` for Bard's target, `bard run`, and a row-by-row
  comparison of every model. The second round runs over existing relations,
  so it covers view and table swaps and incremental merges.
  """

  use ExUnit.Case, async: false

  alias Bard.Adapter.Postgres
  alias Bard.Test.RunParity

  @moduletag :run_parity
  @moduletag timeout: :infinity

  setup_all do
    dir =
      System.get_env("BARD_RUN_PARITY_PROJECT") ||
        raise "Set BARD_RUN_PARITY_PROJECT to a dbt project to run this test."

    dir = Path.expand(dir)
    dbt_target = System.get_env("BARD_RUN_PARITY_DBT_TARGET", "dbt_ref")
    bard_target = System.get_env("BARD_RUN_PARITY_BARD_TARGET", "bard_out")

    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, target} = Bard.Profile.load(dir, target: bard_target)
    {:ok, conn} = Postgres.connect(target)

    for t <- [dbt_target, bard_target],
        do: RunParity.dbt!(dir, ["seed", "--target", t, "--full-refresh"])

    %{dir: dir, dbt_target: dbt_target, bard_target: bard_target, conn: conn}
  end

  test "two rounds of bard run match dbt run, model by model", ctx do
    for round <- 1..2 do
      RunParity.dbt!(ctx.dir, ["run", "--target", ctx.dbt_target])
      dbt_relations = RunParity.relations(ctx.dir)

      RunParity.dbt!(ctx.dir, ["compile", "--target", ctx.bard_target])
      bard_relations = RunParity.relations(ctx.dir)

      assert {:ok, %{error: 0, skip: 0}} =
               Bard.CLI.Run.run([project_dir: ctx.dir, target: ctx.bard_target], fn _ -> :ok end)

      differences = RunParity.compare(Postgres, ctx.conn, dbt_relations, bard_relations)

      assert differences == [],
             "round #{round}: #{length(differences)} models differ:\n#{inspect(differences, pretty: true)}"
    end
  end
end
