defmodule Bard.Test.FakeAdapter do
  @moduledoc """
  An in-memory adapter: it records statements instead of running them.

      {:ok, conn} = FakeAdapter.connect(%{
        existing: %{"marts.orders" => %{type: :table, columns: ["id"]}},
        fail_on: ~r/customers/
      })

  `conn` is an Agent. `statements/1` returns everything executed, in order.
  A transaction whose statements match `:fail_on` returns an error and records
  nothing, as a rolled-back transaction would.
  """

  use Boundary, top_level?: true, deps: [Bard, Bard.Adapter]

  @behaviour Bard.Adapter

  alias Bard.Relation

  @impl true
  def connect(target) do
    Agent.start_link(fn ->
      %{
        existing: Map.get(target, :existing, %{}),
        fail_on: Map.get(target, :fail_on),
        schemas: MapSet.new(),
        statements: []
      }
    end)
  end

  @impl true
  def disconnect(conn), do: Agent.stop(conn)

  @impl true
  def ensure_schema(conn, %Relation{schema: schema}) do
    Agent.update(conn, &%{&1 | schemas: MapSet.put(&1.schemas, schema)})
  end

  @impl true
  def describe(conn, %Relation{schema: schema, identifier: identifier}) do
    {:ok, Agent.get(conn, & &1.existing["#{schema}.#{identifier}"])}
  end

  @impl true
  def transaction(conn, statements) do
    Agent.get_and_update(conn, fn state ->
      if state.fail_on && Enum.any?(statements, &Regex.match?(state.fail_on, &1)) do
        {{:error, :fake_failure}, state}
      else
        {{:ok, %{rows_affected: nil}}, %{state | statements: state.statements ++ statements}}
      end
    end)
  end

  @impl true
  def query(_conn, _sql), do: {:ok, []}

  def statements(conn), do: Agent.get(conn, & &1.statements)
  def schemas(conn), do: Agent.get(conn, & &1.schemas)
end
