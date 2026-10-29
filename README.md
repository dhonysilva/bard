# Bard

Bard can read any dbt project and answer questions about its structure without dbt running. It loads the `manifest.json` from `dbt parse` (schema v10–v12) into Elixir structs, builds the lineage graph, checks it for cycles and broken references, and selects nodes with dbt’s `--select` syntax. What it can’t do yet is touch the warehouse: no SQL execution, no Jinja compiling, no running tests.

Activities we can perform today.

Run the this project on a real project. This is the most valuable step:

```shell
cd ../your_dbt_project && dbt parse && cd -
BARD_PARITY_PROJECT=../your_dbt_project mix test --only parity
```

List nodes like `dbt ls`, without dbt.


```shell
mix bard.ls --project-dir ../your_dbt_project -s "tag:daily" --output name
mix bard.ls --project-dir ../your_dbt_project -s "@stg_orders" --exclude "resource_type:test"
```

For now, you can use the fixture project:

```shell
mix bard.ls --project-dir test/fixtures/jaffle_shop -s "tag:daily" --output name
```

And see the result:

```shell
customers
not_null_orders_order_id
orders
relationships_orders_customer_id__customer_id__ref_customers_
unique_customers_customer_id
```

Analyse the project in `iex -S mix`. Start with:

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

These checks are useful on client projects right away, for example as a project health check or an impact review before a refactor.

What’s next?

The executor: take dbt’s compiled SQL from `target/compiled`, run each wave against Postgres or DuckDB with Postgrex or ADBC, and add retries and Telemetry. Its gate is that row counts and checksums match `dbt run`.

The structure

Config → Node → Graph → Project → Loader → Loader.Manifest
                                       ↘
           Selector.Parser → Selector → CLI → CLI.Ls → mix bard.ls → Parity


```
iex -S mix
```

```
Bard.Project.load(Bard.Loader.Manifest, project_dir: "test/fixtures/jaffle_shop")
```

Return a project with its graph built.

**TODO: Add description**

## Installation

```elixir
mix bard.run --project-dir test/fixtures/jaffle_shop -s +orders
```
