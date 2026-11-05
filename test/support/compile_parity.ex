defmodule Bard.Test.CompileParity do
  @moduledoc """
  The Phase 3 gate: Bard's compiler and `dbt compile` must agree, node by
  node, on what Bard uses: relation name, dependencies, materialization,
  tags, fqn and compiled SQL.

  `compare/2` returns one entry per node: `:same`, `:whitespace` (the SQL
  differs only in whitespace) or `{:different, fields}`.
  """

  use Boundary, top_level?: true, deps: [Bard]

  alias Bard.Project

  @types [:model, :seed, :source]

  @spec compare(Project.t(), Project.t()) :: %{String.t() => term()}
  def compare(%Project{} = dbt, %Project{} = bard) do
    for {id, d} <- dbt.nodes, d.resource_type in @types, into: %{} do
      {id, compare_node(d, bard.nodes[id])}
    end
  end

  defp compare_node(_dbt, nil), do: {:different, [:missing]}

  defp compare_node(d, b) do
    fields =
      for {field, get} <- [
            relation_name: & &1.relation_name,
            depends_on: &Enum.sort(&1.depends_on),
            materialized: & &1.config.materialized,
            tags: &Enum.sort(&1.config.tags),
            fqn: & &1.fqn,
            compiled_code: & &1.compiled_code
          ],
          get.(d) != get.(b),
          do: {field, get.(d), get.(b)}

    case fields do
      [] ->
        :same

      [{:compiled_code, dbt_sql, bard_sql}] ->
        if normalize(dbt_sql) == normalize(bard_sql),
          do: :whitespace,
          else: {:different, fields}

      _ ->
        {:different, fields}
    end
  end

  defp normalize(nil), do: nil
  defp normalize(sql), do: sql |> String.split() |> Enum.join(" ")

  @doc "Counts per outcome, for the test's report."
  @spec summary(map()) :: %{same: integer(), whitespace: integer(), different: integer()}
  def summary(results) do
    Enum.reduce(results, %{same: 0, whitespace: 0, different: 0}, fn
      {_, :same}, acc -> Map.update!(acc, :same, &(&1 + 1))
      {_, :whitespace}, acc -> Map.update!(acc, :whitespace, &(&1 + 1))
      {_, {:different, _}}, acc -> Map.update!(acc, :different, &(&1 + 1))
    end)
  end
end
