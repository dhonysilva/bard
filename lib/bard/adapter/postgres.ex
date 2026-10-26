defmodule Bard.Adapter.Postgres do
  @moduledoc """
  Postgres adapter, built on Postgrex.

  `connect/1` takes a target from `Bard.Profile` (`host`, `port`, `user`,
  `password`, `dbname`, `threads`) and starts a pool with one connection per
  thread, so every running model has its own connection.

  Queries run without a timeout: a model can legitimately take hours, and
  Postgrex's default (15 seconds) would kill it.
  """

  @behaviour Bard.Adapter

  alias Bard.Relation

  @no_timeout [timeout: :infinity]

  @impl true
  def connect(target) do
    opts = [
      hostname: Map.get(target, :host, "localhost"),
      port: Map.get(target, :port, 5432),
      username: Map.get(target, :user),
      password: Map.get(target, :password),
      database: Map.get(target, :dbname),
      pool_size: Map.get(target, :threads, 4),
      backoff_type: :stop,
      show_sensitive_data_on_connection_error: false
    ]

    # start_link connects in the background; one query proves it works.
    with {:ok, pool} <- Postgrex.start_link(opts) do
      case Postgrex.query(pool, "select 1", []) do
        {:ok, _} ->
          {:ok, pool}

        {:error, error} ->
          GenServer.stop(pool)
          {:error, {:connection_failed, Exception.message(error)}}
      end
    end
  end

  @impl true
  def disconnect(pool), do: GenServer.stop(pool)

  @impl true
  def ensure_schema(pool, %Relation{schema: schema}) do
    case Postgrex.query(pool, "create schema if not exists #{Relation.quote_ident(schema)}", []) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  @describe """
  select c.relkind::text, a.attname::text
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_attribute a
    on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  where n.nspname = $1 and c.relname = $2
  order by a.attnum
  """

  @impl true
  def describe(pool, %Relation{schema: schema, identifier: identifier}) do
    case Postgrex.query(pool, @describe, [schema, identifier]) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[kind, _] | _] = rows}} ->
        columns = for [_, column] <- rows, column, do: column
        {:ok, %{type: type(kind), columns: columns}}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp type(kind) when kind in ["r", "p"], do: :table
  defp type("v"), do: :view
  defp type(_), do: :other

  @impl true
  def transaction(pool, statements) do
    Postgrex.transaction(
      pool,
      fn conn ->
        Enum.reduce(statements, nil, fn sql, rows ->
          case Postgrex.query(conn, sql, [], @no_timeout) do
            # CREATE TABLE AS reports SELECT n; incremental inserts report INSERT n.
            {:ok, %{command: command, num_rows: n}} when command in [:select, :insert] -> n
            {:ok, _} -> rows
            {:error, error} -> Postgrex.rollback(conn, Exception.message(error))
          end
        end)
      end,
      @no_timeout
    )
    |> case do
      {:ok, rows} -> {:ok, %{rows_affected: rows}}
      {:error, message} -> {:error, message}
    end
  end

  @impl true
  def query(pool, sql) do
    case Postgrex.query(pool, sql, [], @no_timeout) do
      {:ok, %{rows: rows}} -> {:ok, rows || []}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
