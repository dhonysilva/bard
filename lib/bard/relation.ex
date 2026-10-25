defmodule Bard.Relation do
  @moduledoc """
  A table or view in the warehouse: `database.schema.identifier`.

  Bard takes relations from dbt's `relation_name`
  (`"analytics"."marts"."orders"`) instead of computing them, so dbt's
  schema and alias rules apply unchanged.
  """

  @type t :: %__MODULE__{
          database: String.t() | nil,
          schema: String.t(),
          identifier: String.t()
        }

  @enforce_keys [:schema, :identifier]
  defstruct [:database, :schema, :identifier]

  # Postgres truncates identifiers longer than this.
  @max_identifier 63

  # One part: a quoted identifier ("" escapes a quote) or an unquoted run.
  @part ~r/\G(?:"((?:[^"]|"")*)"|([^".\s]+))(\.|\z)/

  @doc """
  Parses a relation name with two or three parts, quoted or not.

      iex> Bard.Relation.parse(~s("analytics"."marts"."orders"))
      {:ok, %Bard.Relation{database: "analytics", schema: "marts", identifier: "orders"}}
  """

  @spec parse(String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse(nil), do: {:error, :no_relation}

  def parse(name) when is_binary(name) do
    case parts(String.trim(name), 0, []) do
      {:ok, [database, schema, identifier]} ->
        {:ok, %__MODULE__{database: database, schema: schema, identifier: identifier}}

      {:ok, [schema, identifier]} ->
        {:ok, %__MODULE__{schema: schema, identifier: identifier}}

      _ ->
        {:error, {:invalid_relation, name}}
    end
  end

  defp parts(name, offset, acc) do
    case Regex.run(@part, name, offset: offset, return: :index) do
      [{start, len} | groups] when start == offset ->
        part = part_value(name, groups)

        case List.last(groups) do
          {_, 0} -> {:ok, Enum.reverse([part | acc])}
          _dot -> parts(name, start + len, [part | acc])
        end

      _ ->
        :error
    end
  end

  defp part_value(name, [{qs, ql} | _]) when qs >= 0,
    do: name |> binary_part(qs, ql) |> String.replace(~s(""), ~s("))

  defp part_value(name, [_, {us, ul} | _]), do: binary_part(name, us, ul)

  @doc "The fully quoted name, for use in SQL."
  @spec to_sql(t()) :: String.t()
  def to_sql(%__MODULE__{} = relation) do
    [relation.database, relation.schema, relation.identifier]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", &quote_ident/1)
  end

  @doc "The quoted identifier alone, used where SQL forbids a schema (`alter ... rename to`)."
  @spec quoted_identifier(t()) :: String.t()
  def quoted_identifier(%__MODULE__{identifier: identifier}), do: quote_ident(identifier)

  @doc "Quotes one identifier, doubling any embedded quote."
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  @doc """
  The same relation with a suffix on its identifier, for temporary and backup
  copies. The base is shortened so the result fits Postgres's 63-byte limit.
  """
  @spec with_suffix(t(), String.t()) :: t()
  def with_suffix(%__MODULE__{identifier: identifier} = relation, suffix) do
    base = truncate_bytes(identifier, @max_identifier - byte_size(suffix))
    %{relation | identifier: base <> suffix}
  end

  defp truncate_bytes(string, max) when byte_size(string) <= max, do: string

  defp truncate_bytes(string, max) do
    string
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc <> g) <= max, do: {:cont, acc <> g}, else: {:halt, acc}
    end)
  end
end
