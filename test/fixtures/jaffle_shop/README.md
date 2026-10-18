# jaffle_shop fixture

`target/manifest.json` is a small, hand-made manifest in dbt's v12 shape,
modeled on dbt's jaffle_shop example: 3 seeds, 1 source, 6 models and
4 tests. It keeps unit tests fast and independent of a dbt install.

Replace it with real output once dbt is available:

```bash
git clone https://github.com/dbt-labs/jaffle_shop
cd jaffle_shop && dbt parse
cp target/manifest.json <bard>/test/fixtures/jaffle_shop/target/
```

The unit tests assert the fixture's exact graph, so update them if you swap
in a real manifest. Parity against dbt itself runs separately: see
`test/parity_test.exs`.
