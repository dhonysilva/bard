defmodule Mix.Tasks.Bard.Ls do
  @shortdoc "Lists the nodes a selector picks, like `dbt ls`"

  @moduledoc """
  Lists the nodes of a dbt project that a selector picks, like `dbt ls`.

      mix bard.ls --project-dir ../analytics_dbt --select +orders
      mix bard.ls -s "tag:daily" --exclude "resource_type:test" --output name

  Reads `<project-dir>/target/manifest.json`, so run `dbt parse` first.

  ## Options

    * `--project-dir` - the dbt project; defaults to `BARD_PROJECT_DIR`, then `.`
    * `--target-path` - where dbt writes artifacts; defaults to `target`
    * `-s`, `--select` - nodes to include; repeatable
    * `--exclude` - nodes to leave out; repeatable
    * `--resource-type` - `model`, `seed`, `snapshot`, `test` or `source`; repeatable
    * `--output` - `selector` (default), `name`, `path` or `json`
    * `--indirect-selection` - `eager` (default) or `empty`
  """

  use Mix.Task
  use Boundary, classify_to: Bard.CLI

  alias Bard.CLI
  alias Bard.CLI.Ls

  @switches [
    project_dir: :string,
    target_path: :string,
    select: :keep,
    exclude: :keep,
    resource_type: :keep,
    output: :string,
    indirect_selection: :string
  ]

  @outputs %{"selector" => :selector, "name" => :name, "path" => :path, "json" => :json}

  @resource_types %{
    "model" => :model,
    "seed" => :seed,
    "snapshot" => :snapshot,
    "test" => :test,
    "source" => :source
  }

  @indirect %{"eager" => :eager, "empty" => :empty}

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: [s: :select])

    if invalid != [] or rest != [] do
      Mix.raise("Unexpected arguments: #{inspect(invalid ++ rest)}. See `mix help bard.ls`.")
    end

    project_dir = CLI.project_dir(opts[:project_dir])
    load_opts = [project_dir: project_dir, target_path: Keyword.get(opts, :target_path, "target")]

    ls_opts = [
      select: Keyword.get_values(opts, :select),
      exclude: Keyword.get_values(opts, :exclude),
      resource_types:
        opts
        |> Keyword.get_values(:resource_type)
        |> Enum.map(&lookup!(@resource_types, &1, "--resource-type")),
      output: lookup!(@outputs, Keyword.get(opts, :output, "selector"), "--output"),
      indirect_selection:
        lookup!(
          @indirect,
          Keyword.get(opts, :indirect_selection, "eager"),
          "--indirect-selection"
        )
    ]

    with {:ok, project} <- CLI.load_project(load_opts),
         {:ok, lines} <- Ls.run(project, ls_opts) do
      Enum.each(lines, &Mix.shell().info/1)
    else
      {:error, reason} -> Mix.raise(CLI.format_error(reason))
    end
  end

  defp lookup!(map, key, flag) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Mix.raise(
          "Invalid #{flag} #{key}. Expected one of: #{map |> Map.keys() |> Enum.join(", ")}"
        )
    end
  end
end
