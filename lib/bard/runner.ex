defmodule Bard.Runner do
  @moduledoc """
  Runs a set of nodes in dependency order, with bounded parallelism.

  This is a ready-queue scheduler, not a wave scheduler: a node starts the
  moment all of its selected parents have succeeded, so one slow model only
  delays its own descendants.

      {:ok, ids} = Bard.Selector.select(project, select: "+orders")

      results =
        Bard.Runner.run(project, ids,
          threads: 4,
          retries: 1,
          execute: fn node -> MyAdapter.build(node) end
        )

      results["model.jaffle_shop.orders"]
      #=> {:success, %{attempts: 1, duration_ms: 12}}

  ## Options

    * `:execute` (required) - `fn %Bard.Node{} -> :ok | {:ok, info} | {:error, reason} end`.
      `info` is a map merged into the success result (e.g. `rows_affected`).
      The runner knows nothing about SQL: the caller decides what building
      a node means (Phase 2: materialization plan + adapter).
    * `:threads` - maximum nodes running at once; defaults to 4.
    * `:retries` - extra attempts after an `{:error, _}`; defaults to 0.
      A crash (an exception or exit) is not retried.
    * `:backoff_ms` - wait before retry `n` is `backoff_ms * n`; defaults to 200.

  ## Results

  A map with one entry per id in `ids`:

    * `{:success, %{attempts: n, duration_ms: ms}}`, plus any `info` from `execute`
    * `{:error, reason}` - the last error, or `{:crash, reason}`
    * `{:skipped, failed_id}` - an ancestor failed, so this node never ran

  Parents outside `ids` are treated as already built, as `dbt run -s` does.

  ## Telemetry

    * `[:bard, :node, :start]` and `[:bard, :node, :stop]` (via
      `:telemetry.span/3`), metadata `%{unique_id: id}`; `:stop` adds
      `result:`, the node's result
    * `[:bard, :node, :skipped]`, metadata `%{unique_id: id, failed: id}`
  """

  use Boundary, top_level?: true, deps: [Bard], exports: []

  alias Bard.Graph
  alias Bard.Node
  alias Bard.Project

  @type result ::
          {:success,
           %{
             required(:attempts) => pos_integer(),
             required(:duration_ms) => non_neg_integer(),
             optional(atom()) => term()
           }}
          | {:error, term()}
          | {:skipped, String.t()}

  defmodule State do
    @moduledoc false
    defstruct [
      :project,
      :selected,
      :opts,
      :supervisor,
      # id => number of selected parents that have not succeeded yet
      waiting: %{},
      # ids whose parents are all done, in the order they became ready
      ready: :queue.new(),
      # task monitor ref => id
      running: %{},
      results: %{}
    ]
  end

  @spec run(Project.t(), Enumerable.t(), keyword()) :: %{String.t() => result()}
  def run(%Project{} = project, ids, opts) do
    Keyword.fetch!(opts, :execute)
    selected = MapSet.new(ids)
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      waiting =
        Map.new(selected, fn id ->
          {id, project.graph |> Graph.parents(id) |> Enum.count(&MapSet.member?(selected, &1))}
        end)

      ready =
        project.graph
        |> Graph.topsort()
        |> Enum.filter(&(Map.get(waiting, &1) == 0))
        |> :queue.from_list()

      %State{
        project: project,
        selected: selected,
        opts: opts,
        supervisor: supervisor,
        waiting: Map.drop(waiting, :queue.to_list(ready)),
        ready: ready
      }
      |> loop()
    after
      Supervisor.stop(supervisor)
    end
  end

  # Done: nothing ready, nothing running.
  defp loop(%State{running: running} = state) when map_size(running) == 0 do
    if :queue.is_empty(state.ready), do: state.results, else: state |> dispatch() |> loop()
  end

  defp loop(%State{} = state) do
    state = dispatch(state)

    receive do
      # The task returned. Demonitor with :flush drops its :DOWN message.
      {ref, outcome} when is_map_key(state.running, ref) ->
        Process.demonitor(ref, [:flush])
        state |> finish(ref, outcome) |> loop()

      # The task crashed: an exception or exit inside `execute`.
      {:DOWN, ref, :process, _pid, reason} when is_map_key(state.running, ref) ->
        state |> finish(ref, {:error, {:crash, reason}}) |> loop()
    end
  end

  # Start ready nodes until `threads` are running or nothing is ready.
  defp dispatch(%State{} = state) do
    threads = Keyword.get(state.opts, :threads, 4)

    if map_size(state.running) < threads and not :queue.is_empty(state.ready) do
      {{:value, id}, ready} = :queue.out(state.ready)
      node = state.project.nodes[id]
      task = Task.Supervisor.async_nolink(state.supervisor, fn -> attempt(node, state.opts) end)

      dispatch(%{state | ready: ready, running: Map.put(state.running, task.ref, id)})
    else
      state
    end
  end

  defp finish(state, ref, outcome) do
    {id, running} = Map.pop!(state.running, ref)
    state = %{state | running: running}

    case outcome do
      {:success, _} = success -> state |> record(id, success) |> release_children(id)
      {:error, _} = error -> state |> record(id, error) |> skip_descendants(id)
    end
  end

  # A child becomes ready when its last selected parent succeeds.
  defp release_children(state, id) do
    state.project.graph
    |> Graph.children(id)
    |> Enum.filter(&Map.has_key?(state.waiting, &1))
    |> Enum.reduce(state, fn child, state ->
      case Map.fetch!(state.waiting, child) do
        1 ->
          %{
            state
            | waiting: Map.delete(state.waiting, child),
              ready: :queue.in(child, state.ready)
          }

        n ->
          %{state | waiting: Map.put(state.waiting, child, n - 1)}
      end
    end)
  end

  # Every selected descendant of a failed node is still waiting (it needs
  # the failed node), so removing it from `waiting` means it never runs.
  defp skip_descendants(state, failed) do
    state.project.graph
    |> Graph.descendants(failed)
    |> Enum.filter(&Map.has_key?(state.waiting, &1))
    |> Enum.reduce(state, fn id, state ->
      :telemetry.execute([:bard, :node, :skipped], %{}, %{unique_id: id, failed: failed})
      %{state | waiting: Map.delete(state.waiting, id)} |> record(id, {:skipped, failed})
    end)
  end

  defp record(state, id, result), do: %{state | results: Map.put(state.results, id, result)}

  defp attempt(%Node{} = node, opts) do
    execute = Keyword.fetch!(opts, :execute)
    retries = Keyword.get(opts, :retries, 0)
    backoff = Keyword.get(opts, :backoff_ms, 200)

    :telemetry.span([:bard, :node], %{unique_id: node.unique_id}, fn ->
      started = System.monotonic_time(:millisecond)
      result = attempt(execute, node, 1, retries + 1, backoff, started)
      {result, %{unique_id: node.unique_id, result: result}}
    end)
  end

  defp attempt(execute, node, n, max, backoff, started) do
    case execute.(node) do
      :ok ->
        success(%{}, n, started)

      {:ok, info} when is_map(info) ->
        success(info, n, started)

      {:error, _reason} when n < max ->
        Process.sleep(backoff * n)
        attempt(execute, node, n + 1, max, backoff, started)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp success(info, attempts, started) do
    elapsed = System.monotonic_time(:millisecond) - started
    {:success, Map.merge(info, %{attempts: attempts, duration_ms: elapsed})}
  end
end
