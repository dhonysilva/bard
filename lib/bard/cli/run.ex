defmodule Bard.CLI.Run do
  @moduledoc """
  `bard run`: builds the selected models, like `dbt run`.

  The SQL comes from dbt, so compile first with the same target:

      dbt compile --target prod
      mix bard.run --target prod --select +orders

  Progress lines are printed as models finish, through a Telemetry handler
  on the runner's events. Results are written to
  `<project>/bard_target/run_results.json`.
  """

  alias Bard.Build
  alias Bard.CLI
  alias Bard.Profile
  alias Bard.Project
  alias Bard.RunResults
  alias Bard.Selector

  @adapters %{"postgres" => Bard.Adapter.Postgres}

  @type summary :: %{
          pass: non_neg_integer(),
          error: non_neg_integer(),
          skip: non_neg_integer(),
          results: map(),
          run_results_path: Path.t()
        }

  @doc """
  Options: `:project_dir`, `:target_path`, `:profiles_dir`, `:target`,
  `:select`, `:exclude`, `:threads`, `:retries`, `:full_refresh`.
  `print` receives each progress line.
  """

  @spec run(keyword(), (String.t() -> any())) :: {:ok, summary()} | {:error, term()}
  def run(opts, print \\ &IO.puts/1) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    started = System.monotonic_time(:millisecond)

    with {:ok, project} <-
           CLI.load_project(
             project_dir: project_dir,
             target_path: Keyword.get(opts, :target_path, "target")
           ),
         {:ok, target} <- Profile.load(project_dir, Keyword.take(opts, [:profiles_dir, :target])),
         {:ok, adapter} <- adapter(target),
         {:ok, ids} <- select(project, opts) do
      threads = opts[:threads] || Map.get(target, :threads, 4)
      nodes = Build.runnable(project, ids)

      print.(
        "Running #{length(nodes)} models on #{target.profile}.#{target.name} with #{threads} threads"
      )

      with {:ok, conn} <- adapter.connect(Map.put(target, :threads, threads)) do
        try do
          handler = attach_progress(project, length(nodes), print)

          try do
            build_opts = [
              threads: threads,
              retries: opts[:retries] || 0,
              full_refresh: opts[:full_refresh] || false
            ]

            with {:ok, results} <- Build.run(project, ids, adapter, conn, build_opts) do
              finish(project, project_dir, results, started, print)
            end
          after
            :telemetry.detach(handler)
          end
        after
          adapter.disconnect(conn)
        end
      end
    end
  end

  defp select(project, opts) do
    Selector.select(project,
      select: opts[:select],
      exclude: opts[:exclude],
      resource_types: [:model],
      indirect_selection: :empty
    )
  end

  defp adapter(%{type: type}) do
    case Map.fetch(@adapters, type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_adapter, type}}
    end
  end

  defp attach_progress(project, total, print) do
    handler = "bard-cli-run-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [:atomics])
    config = %{project: project, total: total, print: print, counter: counter}

    :telemetry.attach_many(
      handler,
      [[:bard, :node, :stop], [:bard, :node, :skipped]],
      &__MODULE__.handle_event/4,
      config
    )

    handler
  end

  @doc false
  def handle_event(_event, _measurements, %{unique_id: id} = meta, config) do
    node = config.project.nodes[id]

    # Ephemeral steps are hidden unless they fail, so a failure is never silent.
    unless Build.ephemeral?(node) and not match?(%{result: {:error, _}}, meta),
      do: print_event(node, meta, config)
  end

  defp print_event(node, %{result: result}, config) do
    config.print.(progress(config, describe(node, result)))
  end

  defp print_event(node, %{failed: failed}, config) do
    failed_name = config.project.nodes[failed].name
    config.print.(progress(config, "SKIP  #{label(node)} (#{failed_name} failed)"))
  end

  defp progress(config, text) do
    :counters.add(config.counter, 1, 1)
    n = :counters.get(config.counter, 1)
    width = config.total |> Integer.to_string() |> String.length()
    "#{n |> Integer.to_string() |> String.pad_leading(width)} of #{config.total}  #{text}"
  end

  defp describe(node, {:success, info}) do
    rows = if info[:rows_affected], do: ", #{info.rows_affected} rows", else: ""
    "OK    #{label(node)} (#{format_seconds(info.duration_ms)}#{rows})"
  end

  defp describe(node, {:error, reason}),
    do: "ERROR #{label(node)}: #{RunResults.error_message(reason)}"

  defp label(node), do: "#{node.config.materialized} #{node.relation_name || node.name}"

  defp format_seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 2) <> "s"

  defp finish(%Project{} = project, project_dir, results, started, print) do
    elapsed = System.monotonic_time(:millisecond) - started
    path = Path.join([project_dir, "bard_target", "run_results.json"])
    :ok = RunResults.write(path, RunResults.build(project, results, elapsed))

    counts = Enum.frequencies_by(results, fn {_id, result} -> elem(result, 0) end)
    pass = Map.get(counts, :success, 0)
    error = Map.get(counts, :error, 0)
    skip = Map.get(counts, :skipped, 0)

    print.(
      "Done in #{format_seconds(elapsed)}. PASS=#{pass} ERROR=#{error} SKIP=#{skip} TOTAL=#{map_size(results)}"
    )

    {:ok, %{pass: pass, error: error, skip: skip, results: results, run_results_path: path}}
  end
end
