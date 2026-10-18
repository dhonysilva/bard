defmodule Bard.Config do
  @type materialization ::
          :view
          | :table
          | :incremental
          | :ephemeral
          | :materialized_view
          | :seed
          | :snapshot
          | :test
          | String.t()

  @type t :: %__MODULE__{
          enabled: boolean(),
          materialized: materialization() | nil,
          database: String.t() | nil,
          schema: String.t() | nil,
          alias: String.t() | nil,
          tags: [String.t()],
          meta: map(),
          extra: map()
        }

  defstruct enabled: true,
            materialized: nil,
            database: nil,
            schema: nil,
            alias: nil,
            tags: [],
            meta: %{},
            extra: %{}

  @known ~w(enabled materialized database schema alias tags meta)

  @doc "Builds a config from a dbt-style string-keyed map."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      enabled: Map.get(map, "enabled", true),
      materialized: materialization(map["materialized"]),
      database: map["database"],
      schema: map["schema"],
      alias: map["alias"],
      tags: List.wrap(map["tags"]),
      meta: map["meta"] || %{},
      extra: Map.drop(map, @known)
    }
  end

  @materializations %{
    "view" => :view,
    "table" => :table,
    "incremental" => :incremental,
    "ephemeral" => :ephemeral,
    "materialized_view" => :materialized_view,
    "seed" => :seed,
    "snapshot" => :snapshot,
    "test" => :test
  }

  # Custom materializations are allowed by dbt, so unknown names stay
  # strings instead of becoming atoms.
  defp materialization(nil), do: nil
  defp materialization(name) when is_binary(name), do: Map.get(@materializations, name, name)
end
