defmodule Bard.Test.Fixtures do
  @moduledoc "Paths and loaded projects shared by the test suite."

  use Boundary, top_level?: true, deps: [Bard, Bard.Loader]

  @jaffle_shop Path.expand("../fixtures/jaffle_shop", __DIR__)

  def jaffle_shop_dir, do: @jaffle_shop

  def jaffle_shop do
    {:ok, project} = Bard.Project.load(Bard.Loader.Manifest, project_dir: @jaffle_shop)
    project
  end

  @doc "A short unique_id for readable assertions: `model.jaffle_shop.orders` -> `orders`."
  def short(id) do
    case String.split(id, ".") do
      ["test", _pkg, name, _hash] -> name
      ["source", _pkg, source, table] -> "#{source}.#{table}"
      [_type, _pkg, name] -> name
    end
  end

  def short_set(ids), do: ids |> Enum.map(&short/1) |> Enum.sort()
end
