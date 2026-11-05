defmodule Mix.Tasks.Bard.Compile do
  @shortdoc "Compiles a dbt project with Bard, like `dbt compile`"

  @moduledoc """
  Compiles a dbt project with Bard's own compiler (no dbt needed), like
  `dbt compile`.

      mix bard.compile --project-dir ../analytics_dbt --target dev
      mix bard.compile --offline --vars '{"start_date": "2026-01-01"}'

  Writes the SQL to `<project>/bard_target/compiled/` and stores nodes and
  edges in the warehouse's `bard_meta` schema. Prints warnings and errors
  with their codes (`BARD101`, ...; see `Bard.Compiler.Diagnostic`).

  ## Options

    * `--project-dir` - the dbt project; defaults to `BARD_PROJECT_DIR`, then `.`
    * `--profiles-dir`, `--target` - as for `dbt`
    * `--vars` - YAML or JSON, as for `dbt --vars`
    * `--full-refresh` - `is_incremental()` is false everywhere
    * `--fallback-manifest` - a `manifest.json` from `dbt compile`; models
      Bard cannot compile use dbt's SQL from it (warning BARD401)
    * `--offline` - no warehouse connection: `is_incremental()` is false and
      nothing is written to `bard_meta`
    * `--no-meta` - connect (for `is_incremental()`) but skip `bard_meta`

  Exits with status 1 when compilation fails.
  """

  use Mix.Task
  use Boundary, classify_to: Bard.CLI

  alias Bard.CLI

  @switches [
    project_dir: :string,
    profiles_dir: :string,
    target: :string,
    vars: :string,
    full_refresh: :boolean,
    fallback_manifest: :string,
    offline: :boolean,
    meta: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or rest != [] do
      Mix.raise("Unexpected arguments: #{inspect(invalid ++ rest)}. See `mix help bard.compile`.")
    end

    Mix.Task.run("app.start")

    with {:ok, vars} <- CLI.parse_vars(opts[:vars]),
         {:ok, _summary} <-
           CLI.Compile.run(
             [
               project_dir: CLI.project_dir(opts[:project_dir]),
               profiles_dir: opts[:profiles_dir],
               target: opts[:target],
               vars: vars,
               full_refresh: opts[:full_refresh] || false,
               fallback_manifest: opts[:fallback_manifest],
               offline: opts[:offline] || false,
               meta: Keyword.get(opts, :meta, true)
             ],
             &Mix.shell().info/1
           ) do
      :ok
    else
      {:error, reason} -> Mix.raise(CLI.format_error(reason))
    end
  end
end
