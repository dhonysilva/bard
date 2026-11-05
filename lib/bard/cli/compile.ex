defmodule Bard.CLI.Compile do
  @moduledoc """
  `bard compile`: compiles a dbt project with Bard, like `dbt compile`.

  Writes each model's SQL to `<project>/bard_target/compiled/<package>/<path>`
  (dbt writes `target/compiled/...`, so the two folders can be diffed), and
  stores the project in the warehouse's `bard_meta` schema (`Bard.Meta`).

  `offline: true` needs no warehouse: `is_incremental()` is false and
  nothing is stored.
  """

  alias Bard.CLI
  alias Bard.Meta
  alias Bard.Profile
  alias Bard.Project

  @type summary :: %{
          models: non_neg_integer(),
          by_dbt: [String.t()],
          warnings: non_neg_integer(),
          compiled_dir: Path.t()
        }

  @doc """
  Options: `:project_dir`, `:profiles_dir`, `:target`, `:vars` (a map),
  `:full_refresh`, `:fallback_manifest`, `:offline`, `:meta` (default true).
  """
  @spec run(keyword(), (String.t() -> any())) :: {:ok, summary()} | {:error, term()}
  def run(opts, print \\ &IO.puts/1) do
    project_dir = Keyword.fetch!(opts, :project_dir)

    with {:ok, target} <- Profile.load(project_dir, Keyword.take(opts, [:profiles_dir, :target])) do
      if opts[:offline] do
        compile(project_dir, target, nil, opts, print)
      else
        with {:ok, adapter} <- CLI.adapter(target),
             {:ok, conn} <- adapter.connect(Map.put(target, :threads, 1)) do
          try do
            compile(project_dir, target, {adapter, conn}, opts, print)
          after
            adapter.disconnect(conn)
          end
        end
      end
    end
  end

  defp compile(project_dir, target, connection, opts, print) do
    load_opts = Keyword.take(opts, [:vars, :full_refresh, :fallback_manifest])

    with {:ok, project} <- CLI.compile_project(project_dir, target, connection, load_opts),
         :ok <- store(project, connection, Keyword.get(opts, :meta, true)) do
      Enum.each(CLI.format_diagnostics(project.diagnostics), print)
      dir = Path.join([project_dir, "bard_target", "compiled"])
      models = write_sql(project, dir)
      by_dbt = for node <- models, node.compiled_by == :dbt, do: node.unique_id

      print.(
        "Compiled #{length(models)} models on #{target.profile}.#{target.name}" <>
          if(by_dbt == [], do: "", else: " (#{length(by_dbt)} with dbt's SQL)") <>
          " to #{Path.relative_to_cwd(dir)}"
      )

      {:ok,
       %{
         models: length(models),
         by_dbt: by_dbt,
         warnings: length(project.diagnostics),
         compiled_dir: dir
       }}
    end
  end

  defp store(_project, nil, _meta?), do: :ok
  defp store(_project, _connection, false), do: :ok
  defp store(project, {adapter, conn}, true), do: Meta.write(adapter, conn, project)

  defp write_sql(project, dir) do
    File.rm_rf!(dir)

    for node <- Project.nodes(project), node.resource_type == :model, node.compiled_code do
      path = Path.join([dir, node.package, node.original_file_path])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, node.compiled_code)
      node
    end
  end
end
