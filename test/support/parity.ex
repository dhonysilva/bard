defmodule Bard.Test.Parity do
  @moduledoc """
  Compares Bard's selection with `dbt ls` on a real dbt project.

  This is the Phase 1 gate: for the same selector, both tools must pick
  exactly the same nodes. Only resource types Bard supports are compared.
  """
  use Boundary, top_level?: true, deps: [Bard, Bard.Selector]

  @compared_prefixes ~w(model. seed. snapshot. test. source.)

  @doc "Runs `dbt ls` and returns the selected unique_ids."
  @spec dbt_ls(Path.t(), keyword()) :: {:ok, MapSet.t(String.t())} | {:error, String.t()}

  def dbt_ls(project_dir, opts) do
    args =
      [
        "ls",
        "--project-dir",
        project_dir,
        "--quiet",
        "--output",
        "json",
        "--output-keys",
        "unique_id"
      ] ++
        flag_args("--select", opts[:select]) ++ flag_args("--exclude", opts[:exclude])

    case System.cmd(dbt_executable(), args, stderr_to_stdout: true) do
      {out, 0} ->
        ids =
          out
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, "{"))
          |> Enum.map(&Jason.decode!(&1)["unique_id"])
          |> Enum.filter(&compared?/1)

        {:ok, MapSet.new(ids)}

      {out, status} ->
        {:error, "dbt ls exited with #{status}:\n#{out}"}
    end
  end

  @doc "Runs both tools; returns `:ok` or the differences."
  @spec compare(Bard.Project.t(), keyword()) ::
          :ok | {:mismatch, %{only_dbt: [String.t()], only_bard: [String.t()]}} | {:error, term()}
  def compare(project, opts) do
    with {:ok, from_dbt} <- dbt_ls(project.root, opts),
         {:ok, from_bard} <- Bard.Selector.select(project, opts) do
      from_bard = MapSet.filter(from_bard, &compared?/1)

      if MapSet.equal?(from_dbt, from_bard) do
        :ok
      else
        {:mismatch,
         %{
           only_dbt: from_dbt |> MapSet.difference(from_bard) |> Enum.sort(),
           only_bard: from_bard |> MapSet.difference(from_dbt) |> Enum.sort()
         }}
      end
    end
  end

  def dbt_executable, do: System.get_env("BARD_DBT", "dbt")

  defp compared?(id), do: String.starts_with?(id, @compared_prefixes)

  defp flag_args(_flag, nil), do: []
  defp flag_args(_flag, []), do: []
  defp flag_args(flag, value) when is_binary(value), do: [flag, value]
  defp flag_args(flag, values) when is_list(values), do: [flag | values]
end
