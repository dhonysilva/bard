defmodule Mix.Tasks.Bard.Run do
  @shortdoc "Builds the selected models, like `dbt run`"

  @moduledoc """
  Builds the selected models of a dbt project, like `dbt run`.

      dbt compile --target dev
      mix bard.run --project-dir ../analytics_dbt --target dev --select +orders

  dbt still compiles the SQL in Phase 2, so run `dbt compile` with the same
  target first. Results go to `<project>/bard_target/run_results.json`.

  ## Options

    * `--project-dir` - the dbt project; defaults to `BARD_PROJECT_DIR`, then `.`
    * `--profiles-dir` - folder with `profiles.yml` (dbt's lookup rules otherwise)
    * `--target` - the profile target; defaults to the profile's `target`
    * `--target-path` - where dbt wrote its manifest; defaults to `target`
    * `-s`, `--select` and `--exclude` - repeatable, dbt's syntax
    * `--threads` - models running at once; defaults to the target's `threads`
    * `--retries` - extra attempts for a failed model; defaults to 0
    * `--full-refresh` - rebuild incremental models from scratch (compile
      with `dbt compile --full-refresh` too)

  Exits with status 1 when any model fails.
  """

  use Mix.Task
  use Boundary, classify_to: Bard.CLI

  alias Bard.CLI

  @switches [
    project_dir: :string,
    profiles_dir: :string,
    target: :string,
    target_path: :string,
    select: :keep,
    exclude: :keep,
    threads: :integer,
    retries: :integer,
    full_refresh: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: [s: :select])

    if invalid != [] or rest != [] do
      Mix.raise("Unexpected arguments: #{inspect(invalid ++ rest)}. See `mix help bard.run`.")
    end

    # Starts Postgrex and the other dependencies.
    Mix.Task.run("app.start")

    run_opts = [
      project_dir: CLI.project_dir(opts[:project_dir]),
      target_path: Keyword.get(opts, :target_path, "target"),
      profiles_dir: opts[:profiles_dir],
      target: opts[:target],
      select: Keyword.get_values(opts, :select),
      exclude: Keyword.get_values(opts, :exclude),
      threads: opts[:threads],
      retries: opts[:retries],
      full_refresh: opts[:full_refresh]
    ]

    case CLI.Run.run(run_opts, &Mix.shell().info/1) do
      {:ok, %{error: 0}} -> :ok
      {:ok, %{error: n}} -> Mix.raise("#{n} model(s) failed. See bard_target/run_results.json.")
      {:error, reason} -> Mix.raise(CLI.format_error(reason))
    end
  end
end
