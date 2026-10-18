defmodule BardTest do
  use ExUnit.Case
  doctest Bard

  test "greets the world" do
    assert Bard.hello() == :world
  end
end
