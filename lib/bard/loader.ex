defmodule Bard.Loader do
  @moduledoc """
  A source of projects.

  Every loader returns the same `%Bard.Project{}` (without its graph;
  `Bard.Project.load/2` builds that), which is what lets Phase 3 swap
  dbt's manifest for Bard's own parser without touching anything else.
  """

  use Boundary, top_level?: true, deps: [Bard], exports: [Manifest]

  @callback load(opts :: keyword()) :: {:ok, Bard.Project.t()} | {:error, term()}
end
