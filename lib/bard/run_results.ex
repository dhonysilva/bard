defmodule Bard.RunResults do
  @moduledoc """
  Writes `run_results.json` in dbt's format (schema v6), so tools that read
  dbt's artifacts (dashboards, CI checks, orchestrators) read Bard's too.

  Bard writes to its own folder (`bard_target/` by default), never to dbt's
  `target/`, so the two tools' artifacts can be compared side by side.
  """

  use Boundary, top_level?: true, deps: [Bard, Bard.Runner], exports: []

  alias Bard.Project

  @schema "https://schemas.getdbt.com/dbt/run-results/v6.json"

  @spec build(Project.t(), map(), non_neg_integer()) :: map()
  def build(%Project{} = project, results, elapsed_ms) do
    %{
      "metadata" => %{
        "dbt_schema_version" => @schema,
        "dbt_version" => project.dbt_version,
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "invocation_id" => invocation_id(),
        "generator" => "bard"
      },
      "results" =>
        results
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.map(fn {id, result} -> entry(project.nodes[id], result) end),
      "elapsed_time" => elapsed_ms / 1000,
      "args" => %{"which" => "run"}
    }
  end

  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(path, run_results) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode_to_iodata!(run_results, pretty: true))
    end
  end

  defp entry(node, result) do
    {status, seconds, response, message} =
      case result do
        {:success, info} ->
          rows = info[:rows_affected]

          {"success", info.duration_ms / 1000, %{"rows_affected" => rows},
           rows && "SELECT #{rows}"}

        {:error, reason} ->
          {"error", 0.0, %{}, error_message(reason)}

        {:skipped, failed} ->
          {"skipped", 0.0, %{}, "Skipped because #{failed} failed"}
      end

    %{
      "unique_id" => node.unique_id,
      "status" => status,
      "execution_time" => seconds,
      "adapter_response" => response,
      "message" => message,
      "relation_name" => node.relation_name,
      "compiled" => node.compiled_code != nil,
      "thread_id" => nil,
      "timing" => [],
      "failures" => nil
    }
  end

  @doc false
  def error_message(reason) when is_binary(reason), do: reason

  def error_message({:crash, {exception, _stack}}) when is_exception(exception),
    do: Exception.message(exception)

  def error_message(reason), do: inspect(reason)

  defp invocation_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      Bitwise.band(c, 0x0FFF),
      Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000),
      e
    ])
    |> IO.iodata_to_binary()
  end
end
