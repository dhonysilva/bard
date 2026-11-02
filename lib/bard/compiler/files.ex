defmodule Bard.Compiler.Files do
  @moduledoc """
  Finds a project's files: models, seeds, macros and properties.

  Each file is described by where it lives (`root`, the model or seed path
  it was found under), the path relative to the project
  (`original_file_path`, as dbt reports it), the path relative to its root
  (`path`) and the folders in between (`dirs`, which become the node's fqn).
  """

  @type file :: %{
          abs: Path.t(),
          original_file_path: String.t(),
          path: String.t(),
          dirs: [String.t()],
          name: String.t()
        }

  @doc "Files under `paths` (relative to `project_dir`) with one of `extensions`, sorted."
  @spec find(Path.t(), [String.t()], [String.t()]) :: [file()]
  def find(project_dir, paths, extensions) do
    for root <- paths,
        abs_root = Path.join(project_dir, root),
        File.dir?(abs_root),
        rel <- Path.wildcard(Path.join(abs_root, "**/*")) |> Enum.sort(),
        File.regular?(rel),
        Path.extname(rel) in extensions do
      path = Path.relative_to(rel, abs_root)
      dirs = path |> Path.dirname() |> Path.split() |> Enum.reject(&(&1 == "."))

      %{
        abs: rel,
        original_file_path: Path.join(root, path),
        path: path,
        dirs: dirs,
        name: Path.basename(rel, Path.extname(rel))
      }
    end
  end

  @spec read!(file()) :: String.t()
  def read!(%{abs: abs}), do: File.read!(abs)
end
