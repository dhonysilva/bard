defmodule Bard.Adapter do
  @moduledoc """
  What Bard needs from a warehouse.

  An adapter is a module implementing these callbacks; `conn` is whatever it
  returns from `connect/1`. Materializations never call an adapter: they
  return SQL, and `Bard.Build` hands that SQL to the adapter. That keeps
  every warehouse difference in one module per warehouse.

  Implementations:

    * `Bard.Adapter.Postgres`
    * `Bard.Test.FakeAdapter` (tests): records statements, no database
  """

  use Boundary, top_level?: true, deps: [Bard], exports: [Postgres]

  alias Bard.Relation

  @typedoc "What exists in the warehouse under a relation's name."
  @type existing :: nil | %{type: :table | :view | :other, columns: [String.t()]}

  @type conn :: term()

  @doc "Opens a connection pool from a resolved `Bard.Profile` target."
  @callback connect(target :: map()) :: {:ok, conn} | {:error, term()}

  @doc "Closes the pool."
  @callback disconnect(conn) :: :ok

  @doc "Creates the schema if it does not exist. Called once per schema, before a run."
  @callback ensure_schema(conn, Relation.t()) :: :ok | {:error, term()}

  @doc "Describes the relation currently in the warehouse, or nil."
  @callback describe(conn, Relation.t()) :: {:ok, existing} | {:error, term()}

  @doc """
  Runs statements in one transaction. Returns the rows affected by the
  statement that builds the model (the last one that reports a count).
  """
  @callback transaction(conn, [String.t()]) ::
              {:ok, %{rows_affected: non_neg_integer() | nil}} | {:error, term()}

  @doc "Runs one query and returns its rows. Used by parity checks and tests."
  @callback query(conn, String.t()) :: {:ok, [[term()]]} | {:error, term()}
end
