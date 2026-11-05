defmodule Bard.Compiler.CacheTest do
  use ExUnit.Case, async: true

  alias Bard.Compiler.Cache

  setup do
    dir = Path.join(System.tmp_dir!(), "bard_cache_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{cache_file: Cache.path(dir)}
  end

  test "an entry is reused for the same file hash", %{cache_file: file} do
    entries = Cache.put(%{}, "models/a.sql", "hash1", %{}, :result)
    Cache.save(file, "fp", entries)

    loaded = Cache.load(file, "fp")
    assert Cache.fetch(loaded, "models/a.sql", "hash1") == {:ok, :result}
    assert Cache.fetch(loaded, "models/a.sql", "hash2") == :error
    assert Cache.fetch(loaded, "models/other.sql", "hash1") == :error
  end

  test "another project fingerprint empties the cache", %{cache_file: file} do
    Cache.save(file, "fp", Cache.put(%{}, "models/a.sql", "h", %{}, :result))
    assert Cache.load(file, "other fp") == %{}
  end

  test "a changed env var invalidates the entries that read it" do
    name = "BARD_CACHE_TEST_#{System.unique_integer([:positive])}"
    entries = Cache.put(%{}, "models/a.sql", "h", %{name => nil}, :result)

    assert Cache.fetch(entries, "models/a.sql", "h") == {:ok, :result}
    System.put_env(name, "now set")
    on_exit(fn -> System.delete_env(name) end)
    assert Cache.fetch(entries, "models/a.sql", "h") == :error
  end

  test "a missing or corrupt file is an empty cache, never an error", %{cache_file: file} do
    assert Cache.load(file, "fp") == %{}

    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "not erlang terms")
    assert Cache.load(file, "fp") == %{}
  end

  test "hash/1 is stable for binaries and terms" do
    assert Cache.hash("select 1") == Cache.hash("select 1")
    assert Cache.hash({"a", %{"b" => 1}}) == Cache.hash({"a", %{"b" => 1}})
    assert Cache.hash("a") != Cache.hash("b")
    assert String.length(Cache.hash("x")) == 64
  end
end
