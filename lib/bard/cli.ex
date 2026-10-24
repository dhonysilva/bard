defmodule Bard.CLI do
  @moduledoc """
  Command-line entry points. The `mix bard.*` tasks stay thin: they parse
  flags and call into this boundary, which can later back a standalone
  binary (Burrito or an escript) with no change.
  """

  use Boundary, top_level?: true, deps: [Bard, Bard.Loader, Bard.Selector], exports: [Ls]

  alias Bard.Loader
  alias Bard.Project

  @doc """
  Resolves the dbt project folder: the `--project-dir` flag, then the
  `BARD_PROJECT_DIR` environment variable, then the current folder.
  Relative paths are expanded from the current folder.
  """

  @spec project_dir(String.t() | nil) :: Path.t()
  def project_dir(flag) do
    Path.expand(flag || System.get_env("BARD_PROJECT_DIR") || ".")
  end

  @doc "Loads a project from dbt's manifest."
  @spec load_project(keyword()) :: {:ok, Project.t()} | {:error, term()}
  def load_project(opts), do: Project.load(Loader.Manifest, opts)

  @doc "Turns a Bard error term into a message for people."
  @spec format_error(term()) :: String.t()
  def format_error({:manifest_not_found, path}),
    do: "No manifest at #{path}. Run `dbt parse` in the dbt project first."

  def format_error({:unsupported_manifest_version, version, supported}),
    do:
      "Manifest schema #{version} is not supported yet (supported: #{Enum.join(supported, ", ")})."

  def format_error({:invalid_manifest, path, reason}),
    do: "Invalid manifest at #{path}: #{inspect(reason)}"

  def format_error({:missing_parents, pairs}) do
    lines = Enum.map_join(pairs, "\n", fn {id, parent} -> "  #{id} -> #{parent}" end)
    "Nodes depend on nodes that are not in the project:\n" <> lines
  end

  def format_error({:cycle, cycles}) do
    lines = Enum.map_join(cycles, "\n", &("  " <> Enum.join(&1, ", ")))
    "The project graph has cycles:\n" <> lines
  end

  def format_error({:invalid_criterion, text}), do: "Invalid selector: #{text}"
  def format_error({:invalid_criterion, text, why}), do: "Invalid selector #{text}: #{why}"

  def format_error({:unsupported_method, method}),
    do: "Selector method not supported yet: #{method}:"

  def format_error(:empty_selector), do: "Empty selector."
  def format_error(other), do: inspect(other)
end
