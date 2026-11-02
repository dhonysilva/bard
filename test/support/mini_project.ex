defmodule Bard.Test.MiniProject do
  @moduledoc """
  Writes a small dbt project to a temporary folder, for compiler tests.

      dir = MiniProject.write(%{"models/a.sql" => "select 1"})
  """

  use Boundary, top_level?: true, deps: []

  @target %{
    name: "dev",
    profile: "mini",
    type: "postgres",
    dbname: "db",
    schema: "dev",
    threads: 1
  }

  def target, do: @target

  @doc "Writes `files` (path => content) plus a default dbt_project.yml unless given."
  def write(files, project_yml \\ nil) do
    dir = Path.join(System.tmp_dir!(), "bard_mini_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)

    files = Map.put_new(files, "dbt_project.yml", project_yml || "name: mini\nprofile: mini\n")

    for {path, content} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    dir
  end
end
