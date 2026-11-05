defmodule Bard.CompileParityTest do
  @moduledoc """
  The Phase 3 gate: `bard compile` agrees with `dbt compile`, live.

  Needs dbt and the Postgres of the project's profile:

      mix test --only compile_parity
      BARD_COMPILE_PARITY_PROJECT=../analytics_dbt BARD_COMPILE_PARITY_TARGET=dev \\
        mix test --only compile_parity

  Without `BARD_COMPILE_PARITY_PROJECT`, a copy of `test/fixtures/shop` is
  used. Each project is compiled twice: before anything is built (fresh), and
  after `dbt seed` and `dbt run` (built), so `is_incremental()` is covered both
  ways. Every model, seed and source must match exactly; models that differ
  only in whitespace are reported, and fail the test too.
  """

  use ExUnit.Case, async: false

  alias Bard.Adapter.Postgres
  alias Bard.Test.CompileParity
  alias Bard.Test.RunParity

  @moduletag :compile_parity
  @moduletag timeout: :infinity

  setup_all do
    {dir, target_name} =
      case System.get_env("BARD_COMPILE_PARITY_PROJECT") do
        nil ->
          tmp = Path.join(System.tmp_dir!(), "bard_compile_parity_shop")
          File.rm_rf!(tmp)
          File.cp_r!("test/fixtures/shop", tmp)
          File.rm_rf!(Path.join(tmp, "expected"))
          # dbt looks for profiles.yml in the current folder, not the project's.
          System.put_env("DBT_PROFILES_DIR", tmp)
          {tmp, "dev"}

        dir ->
          {Path.expand(dir), System.get_env("BARD_COMPILE_PARITY_TARGET")}
      end

    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, target} = Bard.Profile.load(dir, target: target_name)
    {:ok, conn} = Postgres.connect(target)
    on_exit(fn -> Postgres.disconnect(conn) end)

    target_args = if target_name, do: ["--target", target_name], else: []
    %{dir: dir, target: target, conn: conn, target_args: target_args}
  end

  defp check(ctx, label) do
    RunParity.dbt!(ctx.dir, ["compile" | ctx.target_args])
    {:ok, dbt} = Bard.Project.load(Bard.Loader.Manifest, project_dir: ctx.dir)

    {:ok, bard} =
      Bard.CLI.compile_project(ctx.dir, ctx.target, {Postgres, ctx.conn}, cache: false)

    results = CompileParity.compare(dbt, bard)
    summary = CompileParity.summary(results)
    IO.puts("\n#{label}: #{inspect(summary)} of #{map_size(results)} nodes")

    different = for {id, outcome} <- results, outcome != :same, do: {id, outcome}
    assert different == [], "#{label}:\n#{inspect(different, pretty: true, limit: :infinity)}"
  end

  test "fresh, then built", ctx do
    # Drop what a previous run built, so "fresh" really is.
    for schema <- schemas(ctx),
        do: Postgres.query(ctx.conn, ~s(drop schema if exists "#{schema}" cascade))

    check(ctx, "fresh")

    RunParity.dbt!(ctx.dir, ["seed", "--full-refresh" | ctx.target_args])
    RunParity.dbt!(ctx.dir, ["run" | ctx.target_args])
    check(ctx, "built")
  end

  # The schemas the project builds into, from dbt's own manifest.
  defp schemas(ctx) do
    RunParity.dbt!(ctx.dir, ["parse" | ctx.target_args])
    {:ok, project} = Bard.Project.load(Bard.Loader.Manifest, project_dir: ctx.dir)

    for node <- Bard.Project.nodes(project),
        node.resource_type in [:model, :seed],
        {:ok, relation} <- [Bard.Relation.parse(node.relation_name)],
        uniq: true,
        do: relation.schema
  end
end
