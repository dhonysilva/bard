defmodule Bard.Selector.ParserTest do
  use ExUnit.Case, async: true

  alias Bard.Selector.Parser

  defp crit(fields) do
    {:criterion,
     Map.merge(%{method: :fqn, parents: nil, children: nil, at: false}, Map.new(fields))}
  end

  test "a plain name uses the fqn method" do
    assert Parser.parse("orders") == {:ok, {:union, [crit(value: "orders")]}}
  end

  test "graph operators with and without depth" do
    assert {:ok, {:union, [c]}} = Parser.parse("+orders")
    assert c == crit(value: "orders", parents: :infinity)

    assert {:ok, {:union, [c]}} = Parser.parse("2+orders+1")
    assert c == crit(value: "orders", parents: 2, children: 1)

    assert {:ok, {:union, [c]}} = Parser.parse("@stg_orders")
    assert c == crit(value: "stg_orders", at: true)
  end

  test "methods" do
    assert {:ok, {:union, [c]}} = Parser.parse("tag:daily+")
    assert c == crit(method: :tag, value: "daily", children: :infinity)

    assert {:ok, {:union, [c]}} = Parser.parse("source:ecom.raw_stores")
    assert c == crit(method: :source, value: "ecom.raw_stores")

    assert {:ok, {:union, [c]}} = Parser.parse("path:models/marts")
    assert c == crit(method: :path, value: "models/marts")
  end

  test "spaces are unions, commas are intersections, repeated flags are unions" do
    assert {:ok, {:union, [a, {:intersection, [b, c]}]}} =
             Parser.parse("orders tag:daily,+customers")

    assert a == crit(value: "orders")
    assert b == crit(method: :tag, value: "daily")
    assert c == crit(value: "customers", parents: :infinity)

    assert Parser.parse(["orders", "customers"]) == Parser.parse("orders customers")
  end

  test "errors" do
    assert Parser.parse("") == {:error, :empty_selector}

    assert Parser.parse("config.materialized:table") ==
             {:error, {:unsupported_method, "config.materialized"}}

    assert Parser.parse("tag:") == {:error, {:invalid_criterion, "tag:", "missing value"}}
    assert {:error, {:invalid_criterion, "@+orders", _}} = Parser.parse("@+orders")
    assert Parser.parse("orders,") == {:error, :empty_criterion}
  end
end
