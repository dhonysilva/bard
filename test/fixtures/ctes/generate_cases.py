"""Expected CTE injection, from dbt itself.

Run from this folder with the project's uv environment (`uv sync` first):

    uv run python generate_cases.py > cases.json
"""
import json
from dbt.compilation import inject_ctes_into_sql
from dbt.contracts.graph.nodes import InjectedCTE

CTE_A = " __dbt__cte__a as (\nselect 1 as x\n)"
CTE_B = " __dbt__cte__b as (\nselect 2 as y\n)"

SQLS = {
    "plain select": "select * from __dbt__cte__a",
    "leading newlines": "\n\nselect * from __dbt__cte__a",
    "leading spaces and tabs": "  \t select 1",
    "with clause": "with x as (select 1) select * from x",
    "with, newline after": "with\n  x as (select 1)\nselect * from x",
    "uppercase WITH": "WITH x AS (SELECT 1) SELECT * FROM x",
    "with recursive": "with recursive t(n) as (select 1) select * from t",
    "leading line comment": "-- a comment\nselect 1",
    "leading block comment": "/* a comment */ select 1",
    "comment then with": "-- note\nwith x as (select 1) select * from x",
    "block comment then with": "/* note */\nwith x as (select 1) select * from x",
    "word starting with with": "without_cte as (select 1)",
    "parenthesised": "(select 1)",
}

cases = {}
for name, sql in SQLS.items():
    for label, ctes in (("one", [CTE_A]), ("two", [CTE_A, CTE_B])):
        injected = inject_ctes_into_sql(sql, [InjectedCTE(id=f"model.p.{i}", sql=c) for i, c in enumerate(ctes)])
        cases[f"{name} ({label} cte)"] = {"sql": sql, "ctes": ctes, "expected": injected}

print(json.dumps(cases, indent=2, sort_keys=True))
