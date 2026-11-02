defmodule Bard.Compiler.Ctes do
  @moduledoc """
  Inlines ephemeral models as CTEs, byte for byte like dbt
  (`dbt/compilation.py`, `_recursively_prepend_ctes` and
  `inject_ctes_into_sql`).

  A model that refs an ephemeral model compiles the ref to
  `__dbt__cte__<identifier>`; the ephemeral SQL is then prepended:

      select * from __dbt__cte__payments
      # becomes
      with __dbt__cte__payments as (
      ...the ephemeral model's SQL...
      ) select * from __dbt__cte__payments

  If the SQL already starts with `with`, the CTEs go right after it (after
  `recursive` for `with recursive`), followed by `, `.
  """

  @type cte :: {unique_id :: String.t(), sql :: String.t()}

  @doc """
  The CTEs a node needs, in dbt's order. `ephemerals` maps a node to the
  ephemeral ids it refs (in first-ref order); `info` maps an ephemeral id to
  `{identifier, pre_injected_sql}`.

  Each ephemeral's own CTEs come before it; an id seen twice keeps its first
  position.
  """
  @spec collect(String.t(), %{String.t() => [String.t()]}, %{
          String.t() => {String.t(), String.t()}
        }) :: [cte()]
  def collect(id, ephemerals, info) do
    id
    |> collect(ephemerals, info, MapSet.new([id]))
    |> Enum.reverse()
  end

  defp collect(id, ephemerals, info, seen) do
    Enum.reduce(Map.get(ephemerals, id, []), [], fn eph, acc ->
      if MapSet.member?(seen, eph), do: raise(ArgumentError, "ephemeral cycle at #{eph}")

      nested = eph |> collect(ephemerals, info, MapSet.put(seen, eph)) |> Enum.reverse()
      {identifier, sql} = Map.fetch!(info, eph)
      cte = {eph, " __dbt__cte__#{identifier} as (\n#{sql}\n)"}
      Enum.reduce(nested ++ [cte], acc, &add/2)
    end)
  end

  # dbt's `_add_prepended_cte`: replace in place when present, else append.
  # `acc` is reversed (newest first).
  defp add({id, _} = cte, acc) do
    if List.keymember?(acc, id, 0), do: List.keyreplace(acc, id, 0, cte), else: [cte | acc]
  end

  @doc "Injects CTEs into SQL as dbt does. No CTEs: the SQL is unchanged."
  @spec inject(String.t(), [cte()]) :: String.t()
  def inject(sql, []), do: sql

  def inject(sql, ctes) do
    joined = Enum.map_join(ctes, ", ", &elem(&1, 1))

    case with_clause(sql) do
      {:with, anchor} ->
        # [sql up to `with`/`recursive`][whitespace][ctes][, ][rest]
        {head, tail} = split_bytes(sql, anchor)
        {space, rest} = split_whitespace(tail)
        head <> space <> joined <> ", " <> rest

      {:none, first} ->
        # [leading whitespace][with][ctes ][sql]
        {head, rest} = split_bytes(sql, first)
        head <> "with" <> joined <> " " <> rest
    end
  end

  # Finds the first token, skipping whitespace and comments (sqlparse's
  # top-level scan). Returns where `with` (or `with recursive`) ends, or the
  # position of the first token that is not whitespace (comments count, as
  # with sqlparse's `token_first()`).
  defp with_clause(sql) do
    first = leading_whitespace(sql)
    start = skip_comments(sql, first)

    case keyword_at(sql, start, "with") do
      {:ok, after_with} ->
        {space, rest} =
          split_whitespace(binary_part(sql, after_with, byte_size(sql) - after_with))

        case keyword_at(rest, 0, "recursive") do
          {:ok, len} -> {:with, after_with + byte_size(space) + len}
          :error -> {:with, after_with}
        end

      :error ->
        {:none, first}
    end
  end

  defp leading_whitespace(sql) do
    byte_size(sql) - byte_size(String.trim_leading(sql))
  end

  defp skip_comments(sql, pos) do
    rest = binary_part(sql, pos, byte_size(sql) - pos)

    cond do
      String.starts_with?(rest, "--") ->
        case :binary.match(rest, "\n") do
          {nl, _} -> skip_ws_then_comments(sql, pos + nl + 1)
          :nomatch -> byte_size(sql)
        end

      String.starts_with?(rest, "/*") ->
        case :binary.match(rest, "*/") do
          {close, _} -> skip_ws_then_comments(sql, pos + close + 2)
          :nomatch -> byte_size(sql)
        end

      true ->
        pos
    end
  end

  defp skip_ws_then_comments(sql, pos) do
    rest = binary_part(sql, pos, byte_size(sql) - pos)
    skip_comments(sql, pos + leading_whitespace(rest))
  end

  # The keyword at `pos`, case-insensitively, followed by a non-word byte.
  defp keyword_at(sql, pos, word) do
    len = byte_size(word)

    with true <- byte_size(sql) >= pos + len,
         true <- String.downcase(binary_part(sql, pos, len)) == word,
         true <- boundary?(sql, pos + len) do
      {:ok, pos + len}
    else
      _ -> :error
    end
  end

  defp boundary?(sql, pos) when pos >= byte_size(sql), do: true

  defp boundary?(sql, pos) do
    <<_::binary-size(pos), c, _::binary>> = sql
    not (c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_)
  end

  defp split_whitespace(string), do: split_bytes(string, leading_whitespace(string))

  defp split_bytes(string, at),
    do: {binary_part(string, 0, at), binary_part(string, at, byte_size(string) - at)}
end
