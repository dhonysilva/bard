defmodule Bard.Compiler.Properties do
  @moduledoc """
  Reads properties files (`schema.yml` and friends): `models:` and `seeds:`
  entries that patch nodes defined elsewhere, and `sources:`.

  Generic tests declared here (`tests:`/`data_tests:`) are kept on columns
  but not turned into nodes yet; that comes with `bard test` (Phase 4).
  """

  alias Bard.Compiler.Config
  alias Bard.Compiler.Yaml

  @type patch :: %{
          config: map(),
          description: String.t() | nil,
          columns: map(),
          file: String.t()
        }

  @type source_table :: %{
          source_name: String.t(),
          name: String.t(),
          database: String.t() | nil,
          schema: String.t(),
          identifier: String.t(),
          config: map(),
          description: String.t() | nil,
          columns: map(),
          file: String.t(),
          dirs: [String.t()]
        }

  @type t :: %{
          models: %{String.t() => patch()},
          seeds: %{String.t() => patch()},
          sources: [source_table()]
        }

  @doc """
  Reads properties files. Each file is `{absolute_path, file, dirs}` where
  `file` is the path shown to people and `dirs` the folders between the
  model path and the file (they become part of a source's fqn).
  """
  @spec load([{Path.t(), String.t(), [String.t()]}], map()) ::
          {t(), [Bard.Compiler.Diagnostic.t()]}
  def load(files, globals) do
    empty = %{models: %{}, seeds: %{}, sources: []}

    Enum.reduce(files, {empty, []}, fn {path, file, dirs}, {acc, diags} ->
      case Yaml.read(path, file) do
        {:ok, raw} ->
          {data, render_diags} = Yaml.render(raw, globals, file)
          {merge_file(acc, data, file, dirs), diags ++ render_diags}

        {:error, diag} ->
          {acc, diags ++ [diag]}
      end
    end)
  end

  defp merge_file(acc, data, file, dirs) do
    %{
      models: Map.merge(acc.models, patches(data["models"], file)),
      seeds: Map.merge(acc.seeds, patches(data["seeds"], file)),
      sources: acc.sources ++ sources(data["sources"], file, dirs)
    }
  end

  defp patches(entries, file) when is_list(entries) do
    for %{"name" => name} = entry <- entries, into: %{} do
      {name,
       %{
         config: entry_config(entry),
         description: entry["description"],
         columns: columns(entry["columns"]),
         file: file
       }}
    end
  end

  defp patches(_entries, _file), do: %{}

  # `config:` plus the older top-level `tags:`/`meta:`/`docs:`.
  defp entry_config(entry) do
    top = Map.take(entry, ~w(tags meta docs))
    Config.merge(top, entry["config"] || %{})
  end

  defp columns(list) when is_list(list) do
    for %{"name" => name} = column <- list, into: %{}, do: {name, column}
  end

  defp columns(_), do: %{}

  defp sources(entries, file, dirs) when is_list(entries) do
    for %{"name" => source_name} = source <- entries,
        %{"name" => name} = table <- List.wrap(source["tables"]) do
      config =
        source
        |> entry_config()
        |> Config.merge(entry_config(table))

      %{
        source_name: source_name,
        name: name,
        database: table["database"] || source["database"],
        schema: table["schema"] || source["schema"] || source_name,
        identifier: table["identifier"] || name,
        config: config,
        description: table["description"],
        columns: columns(table["columns"]),
        file: file,
        dirs: dirs
      }
    end
  end

  defp sources(_entries, _file, _dirs), do: []
end
