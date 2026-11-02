defmodule Bard.Compiler.Cache do
  @moduledoc """
  Remembers what parsing each file found, so an unchanged file is not
  rendered again.

  An entry is reused only when all of these still hold:

    * the file's content hash is the same
    * the project fingerprint is the same: `dbt_project.yml`, every macro,
      the vars and the target (anything a parse can read)
    * every environment variable the file read has the same value

  The cache lives in `bard_target/parse_cache.etf` (Erlang term format). A
  missing, unreadable or old-format file is an empty cache, never an error.
  """

  @version 1

  @type t :: %{optional(String.t()) => {hash :: String.t(), env :: map(), result :: term()}}

  @spec path(Path.t()) :: Path.t()
  def path(project_dir), do: Path.join([project_dir, "bard_target", "parse_cache.etf"])

  @doc "Reads the cache for `fingerprint`; entries made under another fingerprint are dropped."
  @spec load(Path.t(), String.t()) :: t()
  def load(file, fingerprint) do
    with {:ok, binary} <- File.read(file),
         {:ok, {@version, ^fingerprint, entries}} <- decode(binary) do
      entries
    else
      _ -> %{}
    end
  end

  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  @doc "Writes the cache. Failures are ignored: the cache is only an optimisation."
  @spec save(Path.t(), String.t(), t()) :: :ok
  def save(file, fingerprint, entries) do
    File.mkdir_p(Path.dirname(file))
    File.write(file, :erlang.term_to_binary({@version, fingerprint, entries}))
    :ok
  end

  @doc "The cached result for a file, when its hash and env vars still match."
  @spec fetch(t(), String.t(), String.t()) :: {:ok, term()} | :error
  def fetch(entries, file, hash) do
    case Map.fetch(entries, file) do
      {:ok, {^hash, env, result}} ->
        if Enum.all?(env, fn {name, value} -> System.get_env(name) == value end),
          do: {:ok, result},
          else: :error

      _ ->
        :error
    end
  end

  @spec put(t(), String.t(), String.t(), map(), term()) :: t()
  def put(entries, file, hash, env, result), do: Map.put(entries, file, {hash, env, result})

  @doc "A stable hash of any term."
  @spec hash(term()) :: String.t()
  def hash(term) when is_binary(term),
    do: :crypto.hash(:sha256, term) |> Base.encode16(case: :lower)

  def hash(term), do: term |> :erlang.term_to_binary([:deterministic]) |> hash()
end
