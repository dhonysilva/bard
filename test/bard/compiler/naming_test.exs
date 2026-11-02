defmodule Bard.Compiler.NamingTest do
  use ExUnit.Case, async: true

  alias Bard.Compiler.Naming

  @target %{name: "dev", schema: "analytics", dbname: "warehouse"}

  defp model(config), do: %{name: "orders", config: config}

  test "dbt's defaults" do
    assert Naming.relation(model(%{}), @target, %{}) ==
             {:ok, %{database: "warehouse", schema: "analytics", identifier: "orders"}}

    assert Naming.relation(
             model(%{"schema" => "marts", "alias" => "o", "database" => "raw"}),
             @target,
             %{}
           ) ==
             {:ok, %{database: "raw", schema: "analytics_marts", identifier: "o"}}
  end

  test "a project's generate_schema_name macro wins" do
    {:ok, macros} =
      Bard.Jinja.macros("""
      {% macro generate_schema_name(custom_schema_name, node) -%}
        {{ custom_schema_name or 'default' }}_{{ node.name }}
      {%- endmacro %}
      """)

    assert {:ok, %{schema: "marts_orders"}} =
             Naming.relation(model(%{"schema" => "marts"}), @target, macros)

    assert {:ok, %{schema: "default_orders"}} = Naming.relation(model(%{}), @target, macros)
  end

  test "relation_name/1 quotes every part" do
    assert Naming.relation_name(%{database: "db", schema: "s", identifier: ~s(we"ird)}) ==
             ~s("db"."s"."we""ird")
  end
end
