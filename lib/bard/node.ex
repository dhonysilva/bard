defmodule Bard.Node do
  @moduledoc """
  One node of a project: a model, seed, snapshot, test or source.

  This is Bard's own representation. Loaders translate their input
  (dbt's `manifest.json`) into it, and
  nothing past a loader ever sees dbt's manifest shape.
  """

  @type resource_type :: :model | :seed | :snapshot | :test | :source

  @type t :: %__MODULE__{
          unique_id: String.t(),
          resource_type: resource_type(),
          name: String.t(),
          package: String.t(),
          fqn: [String.t()],
          path: String.t() | nil,
          original_file_path: String.t() | nil,
          source_name: String.t() | nil,
          raw_code: String.t() | nil,
          compiled_code: String.t() | nil,
          checksum: String.t() | nil,
          depends_on: [String.t()],
          config: Bard.Config.t(),
          columns: %{optional(String.t()) => map()}
        }

  @enforce_keys [:unique_id, :resource_type, :name, :package]

  defstruct [
    :unique_id,
    :resource_type,
    :name,
    :package,
    :path,
    :original_file_path,
    # Only set for sources: the `source_name` in `sources.yml`.
    :source_name,
    :raw_code,
    :compiled_code,
    :checksum,
    fqn: [],
    depends_on: [],
    config: %Bard.Config{},
    columns: %{}
  ]

  @resource_types [:model, :seed, :snapshot, :test, :source]

  @doc "Resource types Bard understands."
  @spec resource_types() :: [resource_type()]
  def resource_types, do: @resource_types

  @spec tags(t()) :: [String.t()]
  def tags(%__MODULE__{config: config}), do: config.tags

  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{config: config}), do: config.enabled != false
end
