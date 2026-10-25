defmodule Bard.GraphTest do
  use ExUnit.Case, async: true

  alias Bard.Graph
  alias Bard.Node
  alias Bard.Test.Fixtures

  import Fixtures, only: [short_set: 1]

  setup_all do
    %{graph: Fixtures.jaffle_shop().graph}
  end

  test "parents and children", %{graph: graph} do
    assert short_set(Graph.parents(graph, "model.jaffle_shop.orders")) == [
             "stg_orders",
             "stg_payments"
           ]

    assert short_set(Graph.children(graph, "model.jaffle_shop.stg_orders")) ==
             ["customers", "orders", "unique_stg_orders_order_id"]
  end

  test "ancestors, unlimited and by depth", %{graph: graph} do
    assert short_set(Graph.ancestors(graph, "model.jaffle_shop.customers")) ==
             ~w(raw_customers raw_orders raw_payments stg_customers stg_orders stg_payments)

    assert short_set(Graph.ancestors(graph, "model.jaffle_shop.customers", 1)) ==
             ~w(stg_customers stg_orders stg_payments)

    assert Graph.ancestors(graph, "model.jaffle_shop.customers", 0) == MapSet.new()
  end

  test "descendants include tests", %{graph: graph} do
    assert short_set(Graph.descendants(graph, "seed.jaffle_shop.raw_orders")) ==
             ~w(customers not_null_orders_order_id orders
                  relationships_orders_customer_id__customer_id__ref_customers_
                  stg_orders unique_customers_customer_id unique_stg_orders_order_id)
  end

  test "topsort puts every parent before its children", %{graph: graph} do
    order = graph |> Graph.topsort() |> Enum.with_index() |> Map.new()

    for {child, _} <- order, parent <- Graph.parents(graph, child) do
      assert order[parent] < order[child], "#{parent} should come before #{child}"
    end
  end

  test "refuses a dependency on an unknown node" do
    nodes = %{"model.p.a" => node("model.p.a", ["model.p.missing"])}

    assert Graph.build(nodes) == {:error, {:missing_parents, [{"model.p.a", "model.p.missing"}]}}
  end

  test "refuses cycles and names them" do
    nodes = %{
      "model.p.a" => node("model.p.a", ["model.p.b"]),
      "model.p.b" => node("model.p.b", ["model.p.a"]),
      "model.p.c" => node("model.p.c", [])
    }

    assert Graph.build(nodes) == {:error, {:cycle, [["model.p.a", "model.p.b"]]}}
  end

  test "refuses a node that depends on itself" do
    nodes = %{"model.p.a" => node("model.p.a", ["model.p.a"])}

    assert Graph.build(nodes) == {:error, {:cycle, [["model.p.a"]]}}
  end

  defp node(id, deps) do
    %Node{unique_id: id, resource_type: :model, name: id, package: "p", depends_on: deps}
  end
end
