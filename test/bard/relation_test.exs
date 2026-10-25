defmodule Bard.RelationTest do
  use ExUnit.Case, async: true

  alias Bard.Relation

  doctest Bard.Relation

  test "parses quoted and unquoted names with two or three parts" do
    assert {:ok, %Relation{database: "db", schema: "marts", identifier: "orders"}} =
             Relation.parse(~s("db"."marts"."orders"))

    assert {:ok, %Relation{database: nil, schema: "marts", identifier: "orders"}} =
             Relation.parse("marts.orders")

    assert {:ok, %Relation{schema: "Marts", identifier: "my.table"}} =
             Relation.parse(~s("Marts"."my.table"))
  end

  test "unescapes doubled quotes and escapes them again in SQL" do
    {:ok, relation} = Relation.parse(~s("db"."s"."say ""hi"""))
    assert relation.identifier == ~s(say "hi")
    assert Relation.to_sql(relation) == ~s("db"."s"."say ""hi""")
  end

  test "rejects names that are not two or three parts" do
    assert Relation.parse("orders") == {:error, {:invalid_relation, "orders"}}
    assert Relation.parse("a.b.c.d") == {:error, {:invalid_relation, "a.b.c.d"}}
    assert Relation.parse(~s("unclosed.x)) == {:error, {:invalid_relation, ~s("unclosed.x)}}
    assert Relation.parse(nil) == {:error, :no_relation}
  end

  test "suffixes stay within Postgres's 63-byte identifier limit" do
    relation = %Relation{schema: "s", identifier: String.duplicate("a", 60)}
    suffixed = Relation.with_suffix(relation, "__bard_backup")

    assert byte_size(suffixed.identifier) == 63
    assert String.ends_with?(suffixed.identifier, "__bard_backup")

    assert Relation.with_suffix(%Relation{schema: "s", identifier: "orders"}, "__x").identifier ==
             "orders__x"
  end
end
