defmodule Bard.Compiler.Naming do
  @moduledoc """
  Where a node is built: database, schema and identifier.

  dbt decides with three macros a project may override:
  `generate_database_name`, `generate_schema_name` and `generate_alias_name`.
  When the project defines one, it is called (it is Jinja, rendered by
  `Bard.Jinja`); otherwise dbt's default rule is applied in Elixir:

    * database: the `database` config, else `target.database`
    * schema: `target.schema`, or `<target.schema>_<custom>` with a `schema` config
    * identifier: the `alias` config, else the node's name
  """

  alias Bard.Compiler.Context
  alias Bard.Jinja
  alias Bard.Jinja.Object

  @type relation :: %{database: String.t() | nil, schema: String.t(), identifier: String.t()}

  @doc """
  Resolves the relation of a node. `node` is a map with `:name`, `:config`
  (string keys) and what macros may read; `globals` are the base globals
  (they hold the project's macros).
  """

  @spec relation(map(), map(), map()) :: {:ok, relation()} | {:error, Jinja.Error.t()}

  def relation(node, target, globals) do
    config = node.config
    node_object = node_object(node)

    with {:ok, database} <-
           generate(globals, "generate_database_name", [config["database"], node_object], fn ->
             default_database(config["database"], target)
           end),
         {:ok, schema} <-
           generate(globals, "generate_schema_name", [config["schema"], node_object], fn ->
             default_schema(config["schema"], target)
           end),
         {:ok, identifier} <-
           generate(globals, "generate_alias_name", [config["alias"], node_object], fn ->
             default_alias(config["alias"], node.name)
           end) do
      {:ok, %{database: database, schema: schema, identifier: identifier}}
    end
  end

  defp generate(globals, name, args, default) do
    case Map.get(globals, name) do
      %Jinja.Macro{} = macro ->
        with {:ok, value} <- Jinja.call(macro, args, %{}, globals) do
          {:ok, value |> Jinja.Value.to_s() |> String.trim()}
        end

      _ ->
        {:ok, default.()}
    end
  end

  @doc "dbt's default `generate_database_name`."
  @spec default_database(String.t() | nil, map()) :: String.t() | nil
  def default_database(nil, target), do: target[:dbname]
  def default_database(custom, _target), do: String.trim(custom)

  @doc "dbt's default `generate_schema_name`."
  @spec default_schema(String.t() | nil, map()) :: String.t()
  def default_schema(nil, target), do: target[:schema]
  def default_schema(custom, target), do: "#{target[:schema]}_#{String.trim(custom)}"

  @doc "dbt's default `generate_alias_name`."
  @spec default_alias(String.t() | nil, String.t()) :: String.t()
  def default_alias(nil, name), do: name
  def default_alias(custom, _name), do: String.trim(custom)

  @doc ~S|The quoted relation name dbt stores as `relation_name`: `"db"."schema"."id"`.|
  @spec relation_name(relation()) :: String.t()
  def relation_name(%{database: d, schema: s, identifier: i}), do: Context.quoted([d, s, i])

  defp node_object(node) do
    %Object{
      str: node.name,
      attrs: %{
        "name" => node.name,
        "unique_id" => node[:unique_id],
        "resource_type" => node[:resource_type] && to_string(node[:resource_type]),
        "package_name" => node[:package],
        "fqn" => node[:fqn],
        "original_file_path" => node[:original_file_path],
        "config" => node.config
      }
    }
  end
end
