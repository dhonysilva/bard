defmodule Bard.Loader.Manifest do
  @moduledoc """
  Loads a project from the `manifest.json` that `dbt parse` writes.

  This module is the only place in Bard that knows dbt's manifest shape.

  ## Options

    * `:project_dir` - the dbt project folder. The manifest is read from
      `<project_dir>/<target_path>/manifest.json`.
    * `:target_path` - defaults to `"target"`.
    * `:manifest_path` - an explicit path; overrides the two options above.

  Only manifest schema versions in `supported_versions/0` are accepted.
  A newer dbt version produces a clear error instead of a silently
  wrong project.
  """

  @behaviour Bard.Loader

  alias Bard.Config
  alias Bard.Node
  alias Bard.Project

  @supported_versions ~w(v10 v11 v12)

  # Manifest node types Bard models in Phase 1. Others (analyses,
  # operations, unit tests) are skipped until a phase needs them.
  @node_types %{
    "model" => :model,
    "seed" => :seed,
    "snapshot" => :snapshot,
    "test" => :test
  }

  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @impl true
  def load(opts) do
    with {:ok, path} <- manifest_path(opts),
         {:ok, body} <- read(path),
         {:ok, manifest} <- decode(body, path),
         {:ok, version} <- schema_version(manifest) do
      {:ok, to_project(manifest, version, opts)}
    end
  end

  @doc "Converts an already decoded manifest map. Used by `load/1` and in tests."
  @spec from_map(map(), keyword()) :: {:ok, Project.t()} | {:error, term()}
  def from_map(manifest, opts \\ []) do
    with {:ok, version} <- schema_version(manifest) do
      {:ok, to_project(manifest, version, opts)}
    end
  end

  defp manifest_path(opts) do
    cond do
      path = opts[:manifest_path] ->
        {:ok, Path.expand(path)}

      dir = opts[:project_dir] ->
        target = Keyword.get(opts, :target_path, "target")
        {:ok, Path.expand(Path.join([dir, target, "manifest.json"]))}

      true ->
        {:error, :missing_project_dir}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, {:manifest_not_found, path}}
      {:error, reason} -> {:error, {:manifest_unreadable, path, reason}}
    end
  end

  defp decode(body, path) do
    case Jason.decode(body) do
      {:ok, %{} = manifest} -> {:ok, manifest}
      {:ok, _other} -> {:error, {:invalid_manifest, path, :not_an_object}}
      {:error, error} -> {:error, {:invalid_manifest, path, Exception.message(error)}}
    end
  end

  defp schema_version(%{"metadata" => %{"dbt_schema_version" => url}}) when is_binary(url) do
    version = url |> Path.basename() |> Path.rootname()

    if version in @supported_versions do
      {:ok, version}
    else
      {:error, {:unsupported_manifest_version, version, @supported_versions}}
    end
  end

  defp schema_version(_manifest), do: {:error, {:invalid_manifest, :missing_schema_version}}

  defp to_project(manifest, version, opts) do
    metadata = manifest["metadata"] || %{}

    nodes =
      manifest
      |> Map.get("nodes", %{})
      |> Map.values()
      |> Enum.filter(&Map.has_key?(@node_types, &1["resource_type"]))
      |> Enum.map(&to_node/1)

    sources =
      manifest
      |> Map.get("sources", %{})
      |> Map.values()
      |> Enum.map(&to_source/1)

    %Project{
      name: metadata["project_name"],
      root: opts[:project_dir] && Path.expand(opts[:project_dir]),
      dbt_version: metadata["dbt_version"],
      schema_version: version,
      nodes: Map.new(nodes ++ sources, &{&1.unique_id, &1})
    }
  end

  defp to_node(raw) do
    %Node{
      unique_id: raw["unique_id"],
      resource_type: Map.fetch!(@node_types, raw["resource_type"]),
      name: raw["name"],
      package: raw["package_name"],
      fqn: raw["fqn"] || [],
      path: raw["path"],
      original_file_path: raw["original_file_path"],
      raw_code: raw["raw_code"],
      compiled_code: raw["compiled_code"],
      checksum: get_in(raw, ["checksum", "checksum"]),
      depends_on: get_in(raw, ["depends_on", "nodes"]) || [],
      config: config(raw),
      columns: raw["columns"] || %{}
    }
  end

  defp to_source(raw) do
    %Node{
      unique_id: raw["unique_id"],
      resource_type: :source,
      name: raw["name"],
      package: raw["package_name"],
      source_name: raw["source_name"],
      fqn: raw["fqn"] || [],
      path: raw["path"],
      original_file_path: raw["original_file_path"],
      depends_on: [],
      config: config(raw),
      columns: raw["columns"] || %{}
    }
  end

  # dbt resolves tags from config, folder-level settings and the node's own
  # `tags:` into the top-level "tags" list; that is what selection uses.
  defp config(raw) do
    config = raw["config"] || %{}
    Config.from_map(Map.put(config, "tags", raw["tags"] || config["tags"] || []))
  end
end
