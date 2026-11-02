defmodule Bard.Compiler.Config do
  @moduledoc """
  Resolves a node's config the way dbt does, from least to most specific:

    1. `dbt_project.yml`, walking the folder tree along the node's fqn
       (`models: {shop: {marts: {+materialized: table}}}`)
    2. the node's entry in a properties file (`schema.yml`, `config:`)
    3. `{{ config(...) }}` calls in the node's own file

  Later levels override earlier ones, except `tags` (added together) and
  `meta` (merged key by key).

  Keys in `dbt_project.yml` may be written with `+` (always config) or
  without (dbt v1 style): then a key is config when it is a known config
  name or its value is not a map; a map under an unknown key is a subfolder.

  The result is validated: a wrong type is an error (BARD101), an unknown
  key a warning (BARD102), and the known keys become a `%Bard.Config{}`.
  """

  alias Bard.Compiler.Diagnostic

  # Config whose values are maps, so a map under them is not a subfolder.
  @map_configs ~w(meta persist_docs quoting column_types docs grants contract labels)

  @map {:map, :any, :any}
  @string_or_nil {:or, [:string, nil]}
  @hook {:or, [:string, {:list, {:or, [:string, @map]}}, nil]}

  @schema NimbleOptions.new!(
            enabled: [type: :boolean],
            materialized: [type: :string],
            database: [type: @string_or_nil],
            schema: [type: @string_or_nil],
            alias: [type: @string_or_nil],
            tags: [type: {:or, [:string, {:list, :string}]}],
            meta: [type: @map],
            unique_key: [type: {:or, [:string, {:list, :string}, nil]}],
            incremental_strategy: [type: @string_or_nil],
            on_schema_change: [
              type: {:in, ["ignore", "fail", "append_new_columns", "sync_all_columns", nil]}
            ],
            full_refresh: [type: {:or, [:boolean, nil]}],
            "pre-hook": [type: @hook],
            "post-hook": [type: @hook],
            persist_docs: [type: @map],
            quoting: [type: @map],
            column_types: [type: @map],
            docs: [type: @map],
            grants: [type: @map],
            contract: [type: @map],
            labels: [type: @map],
            sql_header: [type: @string_or_nil],
            quote_columns: [type: {:or, [:boolean, nil]}],
            delimiter: [type: :string],
            indexes: [type: {:list, @map}],
            unlogged: [type: :boolean],
            group: [type: @string_or_nil],
            access: [type: {:in, ["private", "protected", "public"]}],
            packages: [type: {:list, :string}],
            event_time: [type: @string_or_nil],
            batch_size: [type: @string_or_nil],
            lookback: [type: :integer],
            begin: [type: :any],
            concurrent_batches: [type: {:or, [:boolean, nil]}],
            snapshot_meta_column_names: [type: @map],
            strategy: [type: @string_or_nil],
            updated_at: [type: @string_or_nil],
            check_cols: [type: {:or, [:string, {:list, :string}]}],
            target_schema: [type: @string_or_nil],
            target_database: [type: @string_or_nil],
            loaded_at_field: [type: @string_or_nil],
            freshness: [type: {:or, [@map, nil]}],
            severity: [type: :string],
            store_failures: [type: {:or, [:boolean, nil]}],
            where: [type: @string_or_nil],
            limit: [type: {:or, [:integer, nil]}],
            fail_calc: [type: :string],
            warn_if: [type: :string],
            error_if: [type: :string]
          )

  @keys Map.new(Keyword.keys(@schema.schema), &{Atom.to_string(&1), &1})

  @doc "Known config keys."
  @spec known_keys() :: [String.t()]
  def known_keys, do: Map.keys(@keys)

  @doc """
  The config `dbt_project.yml` gives a node: walks `tree` (the
  `models:`/`seeds:`/`sources:` section) along `fqn`, the first element
  being the project name.
  """
  @spec from_tree(map(), [String.t()]) :: map()
  def from_tree(tree, fqn), do: walk(tree, fqn, %{})

  defp walk(_tree, [], acc), do: acc

  defp walk(tree, [part | rest], acc) when is_map(tree) do
    case Map.fetch(tree, part) do
      {:ok, %{} = level} -> walk(level, rest, merge(acc, level_config(level)))
      _ -> acc
    end
  end

  defp walk(_tree, _fqn, acc), do: acc

  @doc "The config keys at one level of the project tree (subfolders left out)."
  @spec level_config(map()) :: map()
  def level_config(level) do
    for {key, value} <- level, config_key?(key, value), into: %{} do
      {String.trim_leading(key, "+"), value}
    end
  end

  defp config_key?("+" <> _, _value), do: true

  defp config_key?(key, value),
    do: key in @map_configs or Map.has_key?(@keys, key) or not is_map(value)

  @doc """
  Merges `override` into `base`: tags add up (no duplicates), `meta` merges
  key by key, everything else is replaced.
  """
  @spec merge(map(), map()) :: map()
  def merge(base, override) do
    Enum.reduce(override, base, fn
      {"tags", tags}, acc ->
        Map.put(acc, "tags", Enum.uniq(List.wrap(acc["tags"]) ++ List.wrap(tags)))

      {"meta", %{} = meta}, acc ->
        Map.put(acc, "meta", Map.merge(acc["meta"] || %{}, meta))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  @doc """
  Validates a resolved config map and builds the `%Bard.Config{}`. Unknown
  keys are kept (in `extra`) with a warning.
  """
  @spec validate(map(), keyword()) :: {Bard.Config.t(), [Diagnostic.t()]}
  def validate(map, location \\ []) do
    {known, unknown} = Map.split(map, Map.keys(@keys))
    opts = for {key, value} <- known, do: {@keys[key], value}

    type_errors =
      case NimbleOptions.validate(opts, @schema) do
        {:ok, _} ->
          []

        {:error, %NimbleOptions.ValidationError{message: message}} ->
          [Diagnostic.new("BARD101", "invalid config: #{message}", location)]
      end

    warnings =
      for key <- Map.keys(unknown) |> Enum.sort() do
        Diagnostic.new(
          "BARD102",
          "unknown config `#{key}` (kept; put custom values under `meta`)",
          location
        )
      end

    config = map |> Map.update("tags", [], &List.wrap/1) |> Bard.Config.from_map()
    {config, type_errors ++ warnings}
  end
end
