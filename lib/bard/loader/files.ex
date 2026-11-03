defmodule Bard.Loader.Files do
  @moduledoc """
  Loads a project from its files, compiled by Bard (`Bard.Compiler`)
  instead of dbt.

  Takes `Bard.Compiler.load/1`'s options, plus:

    * `:fallback_manifest` - a `manifest.json` from `dbt compile`. A node Bard
      cannot compile uses dbt's SQL from it (warning BARD401). Without it,
      such a node fails the load.

  Errors come back as `{:error, {:diagnostics, diagnostics}}`.
  """

  @behaviour Bard.Loader

  alias Bard.Loader.Manifest

  @impl true
  def load(opts) do
    with {:ok, fallback} <- fallback(opts[:fallback_manifest]) do
      Bard.Compiler.load(Keyword.put(opts, :fallback, fallback))
    end
  end

  defp fallback(nil), do: {:ok, %{}}

  defp fallback(path) do
    with {:ok, project} <- Manifest.load(manifest_path: path), do: {:ok, project.nodes}
  end
end
