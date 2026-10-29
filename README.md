# Bard

Bard is an Elixir tool that reads a dbt project and tells you about it — fast, and without dbt running. It loads the `manifest.json` from `dbt parse` (schema v10–v12) into Elixir structs, builds the lineage graph, checks it for cycles and broken references, and selects nodes with dbt's `--select` syntax, just like `dbt ls`.

Bard can also build your models: `mix bard.run` takes the SQL dbt already compiled (`dbt compile`), runs it against Postgres with retries and parallelism, and writes a dbt-compatible `run_results.json`. Bard never parses Jinja or compiles SQL itself. `dbt parse`/`dbt compile` stay in the loop as the step before Bard.

## Why use it

- **Instant selection, no dbt runtime** — `mix bard.ls` answers `dbt ls`-style questions directly from the manifest, with no Python process or warehouse connection involved.
- **Lineage checks for free** — cycle and missing-reference detection run as part of loading a project, so you get a project health check or a pre-refactor impact review almost instantly.
- **A real executor** — `mix bard.run` builds `view`, `table`, incremental, and ephemeral models with retries and bounded parallelism, instrumented with Telemetry. It's validated for correctness by a test suite that diffs its output row-for-row against `dbt run`.
- **A library, not just a CLI** — load a project in `iex` and query it with ordinary Elixir (see below), useful for one-off audits that don't justify a whole dbt macro.

## Installation

Requires Elixir `~> 1.18` and a dbt project you can run `dbt parse` (and, for `bard.run`, `dbt compile`) against.

```shell
mix deps.get
```

Dependencies (see `mix.exs`):

- `jason` for JSON, `libgraph` for the lineage graph
- `telemetry` for build progress events
- `postgrex` for the Postgres adapter
- `yaml_elixir` for reading `profiles.yml`.

## Quickstart: run it against a real project

This is the most valuable first step. It checks that Bard's node selection matches dbt's exactly on your own project:

```shell
cd ../your_dbt_project && dbt parse && cd -
BARD_PARITY_PROJECT=../your_dbt_project mix test --only parity
```

## `mix bard.ls`

It list nodes like `dbt ls`.

Reads `<project-dir>/target/manifest.json`, so run `dbt parse` first.

```shell
mix bard.ls --project-dir ../your_dbt_project --select +orders
mix bard.ls -s "tag:daily" --exclude "resource_type:test" --output name
```

Options:

- `--project-dir` — the dbt project; defaults to `BARD_PROJECT_DIR`, then `.`
- `--target-path` — where dbt writes artifacts; defaults to `target`
- `-s`, `--select` — nodes to include; repeatable
- `--exclude` — nodes to leave out; repeatable
- `--resource-type` — `model`, `seed`, `snapshot`, `test`, or `source`; repeatable
- `--output` — `selector` (default, dbt-style `pkg.folder.name`), `name`, `path`, or `json`
- `--indirect-selection` — `eager` (default, pulls in tests on selected nodes) or `empty`

Try it against the bundled fixture project:

```shell
mix bard.ls --project-dir test/fixtures/jaffle_shop -s "tag:daily" --output name
```

And you will see this result:

```
customers
not_null_orders_order_id
orders
relationships_orders_customer_id__customer_id__ref_customers_
unique_customers_customer_id
```

### Selector syntax

Bard implements a dbt-compatible subset of `--select`/`--exclude`:

- **Space** between criteria = union: `"orders customers"`
- **Comma** between criteria = intersection: `"tag:daily,+orders"`
- **Graph operators**: `+name` (name and all ancestors), `name+` (name and all descendants), `N+name` / `name+N` (depth-bounded ancestors/descendants), `N+name+M` (both bounded), `@name` (name, its descendants, and all ancestors of that family)
- **Methods** (`method:value`, default method is a node/fqn match when no prefix is given): `tag:`, `path:`, `resource_type:`, `package:`, `source:` (e.g. `source:ecom.raw_stores`), each supporting `*` globs

Examples:

```
+orders                      # orders and everything upstream of it
orders+                      # orders and everything downstream of it
2+orders+1                   # 2 ancestor levels, 1 descendant level
@stg_orders                  # stg_orders, its descendants, and all of their ancestors
tag:daily+                   # daily-tagged nodes and everything downstream
tag:daily,+customers         # intersection: daily-tagged AND (customers + its ancestors)
```

dbt's `config.*`-style method modifiers (e.g. `config.materialized:`) aren't supported yet.

## `mix bard.run`

It build models like `dbt run`.

```shell
dbt compile --target dev
mix bard.run --project-dir ../your_dbt_project --target dev --select +orders
```

dbt still compiles the SQL. Run `dbt compile` with the same target first. Bard reads the compiled SQL from the manifest and executes it; it doesn't render Jinja itself.

Options:

- `--project-dir` — the dbt project; defaults to `BARD_PROJECT_DIR`, then `.`
- `--profiles-dir` — folder with `profiles.yml` (dbt's lookup rules otherwise)
- `--target` — the profile target; defaults to the profile's own `target`
- `--target-path` — where dbt wrote its manifest; defaults to `target`
- `-s`, `--select` and `--exclude` — repeatable, same selector syntax as `bard.ls`
- `--threads` — models running at once; defaults to the target's `threads`
- `--retries` — extra attempts for a failed model; defaults to 0
- `--full-refresh` — rebuild incremental models from scratch (pass `--full-refresh` to the preceding `dbt compile` too)

Progress prints per model (`OK`/`ERROR`/`SKIP` with row counts and timing), ending with a `PASS=.. ERROR=.. SKIP=.. TOTAL=..` summary. Results are written to `<project>/bard_target/run_results.json`; the command exits with status 1 if any model fails. Only the Postgres adapter is implemented today.

## Validating correctness

Two parity suites, both excluded from `mix test` by default:

**Selection parity** — checks that Bard selects exactly the same nodes as `dbt ls` for a battery of selectors on your project:

```shell
BARD_PARITY_PROJECT=../your_dbt_project mix test --only parity
```

**Run parity** — the correctness gate for the executor. It runs `dbt run` and `mix bard.run` against two targets of the same database and diffs every resulting table row-for-row, including across incremental merges on a second run. Needs a live Postgres and a profile with two targets:

```shell
BARD_RUN_PARITY_PROJECT=../your_dbt_project \
BARD_RUN_PARITY_DBT_TARGET=dbt_ref \
BARD_RUN_PARITY_BARD_TARGET=bard_out \
mix test --only run_parity
```

## Using Bard as a library

Analyse a project directly from `iex -S mix`:

```elixir
alias Bard.Graph
alias Bard.Project
{:ok, p} = Project.load(Bard.Loader.Manifest, project_dir: "../your_dbt_project")
models = p |> Project.nodes() |> Enum.filter(&(&1.resource_type == :model))
```

```elixir
# Models with no tests
tested = p |> Project.nodes() |> Enum.filter(&(&1.resource_type == :test)) |> Enum.flat_map(& &1.depends_on) |> MapSet.new()
models |> Enum.reject(&MapSet.member?(tested, &1.unique_id)) |> Enum.map(& &1.name)
```

Checks like these are useful on client projects right away — as a project health check, or an impact review before a refactor.

## Architecture

```
Config → Node → Graph → Project → Loader → Loader.Manifest
                   ↓                             ↘
         Selector.Parser → Selector → CLI → CLI.Ls → mix bard.ls → Parity
                   ↓
Profile → Adapter.Postgres → Materialization → Runner → Build → RunResults → CLI.Run → mix bard.run → RunParity
```

## What's next

The remaining gaps are warehouse and compilation breadth, not the executor itself: a DuckDB/ADBC adapter alongside Postgres, and (longer-term) compiling SQL from dbt's raw Jinja directly, rather than requiring `dbt compile` as a separate step.
