defmodule Bard do
  @moduledoc """
  Bard: a dbt-compatible transformation engine on the BEAM.

  This root boundary holds the project model that every other part of
  Bard reads and writes: `Bard.Project`, `Bard.Node`, `Bard.Config` and
  `Bard.Graph` and `Bard.Relation`. It depends on no other Bard boundary.

  Boundaries (checked at compile time by the `boundary` library):

    * `Bard` - the project model (this module's namespace)
    * `Bard.Loader` - turns an input (dbt's manifest today) into a project
    * `Bard.Selector` - dbt's `--select` syntax over the graph
    * `Bard.Runner` - runs nodes in dependency order, in parallel
    * `Bard.Materialization` - turns a node into a plan of SQL statements
    * `Bard.Adapter` - talks to a warehouse (Postgres in Phase 2)
    * `Bard.Profile` - reads dbt's `profiles.yml`
    * `Bard.Build` - connects runner, materializations and adapter
    * `Bard.RunResults` - writes `run_results.json`
    * `Bard.CLI` - `mix bard.*` tasks and their output formats
  """

  use Boundary, deps: [], exports: [Config, Graph, Node, Project, Relation]
end
