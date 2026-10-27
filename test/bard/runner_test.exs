defmodule Bard.RunnerTest do
  use ExUnit.Case, async: true

  # The crash test logs the task's exception on purpose.
  @moduletag :capture_log

  alias Bard.Graph
  alias Bard.Node
  alias Bard.Project
  alias Bard.Runner

  # a ──► b ──► d ──► e        x ──► y   (an independent branch)
  #  └──► c ──┘
  setup do
    spec = %{
      "a" => [],
      "b" => ["a"],
      "c" => ["a"],
      "d" => ["b", "c"],
      "e" => ["d"],
      "x" => [],
      "y" => ["x"]
    }

    nodes =
      Map.new(spec, fn {id, parents} ->
        {id,
         %Node{unique_id: id, resource_type: :model, name: id, package: "p", depends_on: parents}}
      end)

    {:ok, graph} = Graph.build(nodes)
    {:ok, log} = Agent.start_link(fn -> [] end)

    %{project: %Project{nodes: nodes, graph: graph}, all: Map.keys(spec), log: log}
  end

  # An executor that records start/finish events and can fail or crash on demand.
  defp executor(log, behaviour \\ %{}) do
    fn %Node{unique_id: id} ->
      Agent.update(log, &[{:start, id} | &1])
      Process.sleep(10)

      result =
        case behaviour[id] do
          nil -> :ok
          :fail -> {:error, :boom}
          :crash -> raise "crashed"
          fun when is_function(fun, 0) -> fun.()
        end

      Agent.update(log, &[{:finish, id} | &1])
      result
    end
  end

  defp events(log), do: log |> Agent.get(& &1) |> Enum.reverse()

  test "every node starts only after all of its parents finished", ctx do
    results = Runner.run(ctx.project, ctx.all, threads: 3, execute: executor(ctx.log))

    assert Enum.all?(results, &match?({_, {:success, _}}, &1))
    position = ctx.log |> events() |> Enum.with_index() |> Map.new()

    for {id, node} <- ctx.project.nodes, parent <- node.depends_on do
      assert position[{:finish, parent}] < position[{:start, id}],
             "#{id} started before #{parent} finished"
    end
  end

  test "never runs more than `threads` nodes at once", ctx do
    {:ok, counter} = Agent.start_link(fn -> {0, 0} end)

    execute = fn _node ->
      Agent.update(counter, fn {now, peak} -> {now + 1, max(peak, now + 1)} end)
      Process.sleep(20)
      Agent.update(counter, fn {now, peak} -> {now - 1, peak} end)
      :ok
    end

    Runner.run(ctx.project, ctx.all, threads: 2, execute: execute)
    assert {0, 2} == Agent.get(counter, & &1)
  end

  test "a failure skips its descendants and nothing else", ctx do
    results = Runner.run(ctx.project, ctx.all, execute: executor(ctx.log, %{"b" => :fail}))

    assert results["b"] == {:error, :boom}
    assert results["d"] == {:skipped, "b"}
    assert results["e"] == {:skipped, "b"}
    # c is b's sibling and the x branch is independent: both still run.
    for id <- ~w(a c x y), do: assert({:success, _} = results[id])
    refute {:start, "d"} in events(ctx.log)
  end

  test "a crash is reported as an error, not a crashed run", ctx do
    results = Runner.run(ctx.project, ~w(x y), execute: executor(ctx.log, %{"x" => :crash}))

    assert {:error, {:crash, {%RuntimeError{message: "crashed"}, _stack}}} = results["x"]
    assert results["y"] == {:skipped, "x"}
  end

  test "retries an error, then succeeds", ctx do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    flaky = fn ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: {:error, :timeout}, else: :ok
    end

    results =
      Runner.run(ctx.project, ["x"],
        retries: 2,
        backoff_ms: 1,
        execute: executor(ctx.log, %{"x" => flaky})
      )

    assert {:success, %{attempts: 2}} = results["x"]
  end

  test "parents outside the selection count as already built", ctx do
    results = Runner.run(ctx.project, ~w(d e), execute: executor(ctx.log))

    assert Map.keys(results) |> Enum.sort() == ["d", "e"]
    assert [{:start, "d"}, {:finish, "d"}, {:start, "e"}, {:finish, "e"}] == events(ctx.log)
  end

  test "emits telemetry for each node", ctx do
    test_pid = self()

    :telemetry.attach_many(
      "runner-test-#{inspect(test_pid)}",
      [[:bard, :node, :stop], [:bard, :node, :skipped]],
      &__MODULE__.forward/4,
      test_pid
    )

    Runner.run(ctx.project, ~w(x y), execute: executor(ctx.log, %{"x" => :fail}))

    assert_received {[:bard, :node, :stop], "x"}
    assert_received {[:bard, :node, :skipped], "y"}
  end

  def forward(event, _measurements, meta, pid), do: send(pid, {event, meta.unique_id})
end
