# Expected output from dbt

Captured from dbt-core 1.10 with dbt-postgres, target `dev` (schema `shop_dev`,
database `bard`):

- `dbt_compile_fresh.json`: `dbt compile` before anything was built, so
  `is_incremental()` is false everywhere.
- `dbt_compile_built.json`: `dbt seed && dbt run && dbt compile`, so
  `customer_orders` compiles with its incremental filter.

Each file keeps, per model, seed and source: `relation_name`, `depends_on`,
`materialized`, `schema`, `alias`, `tags`, `fqn` and `compiled_code`.
`test/bard/compiler/golden_test.exs` checks Bard's compiler against them
without needing dbt. To refresh them, rerun the commands above and the
extraction script in the test's moduledoc.
