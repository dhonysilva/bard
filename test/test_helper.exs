# Parity tests need dbt and a real project; run them with `mix test --only parity`.
ExUnit.start(exclude: [:parity, :postgres, :run_parity])
