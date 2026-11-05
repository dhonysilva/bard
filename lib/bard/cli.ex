defmodule Bard.CLI do
  @moduledoc """
  Command-line entry points. The `mix bard.*` tasks stay thin: they parse
  flags and call into this boundary, which can later back a standalone
  binary (Burrito or an escript) with no change.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Bard,
      Bard.Loader,
      Bard.Selector,
      Bard.Profile,
      Bard.Adapter,
      Bard.Build,
      Bard.Runner,
      Bard.RunResults,
      Bard.Compiler,
      Bard.Meta
    ],
    exports: [Compile, Ls, Run]

  alias Bard.Loader
  alias Bard.Project
  alias Bard.Relation

  alias Bard.Compiler.Diagnostic

  @adapters %{"postgres" => Bard.Adapter.Postgres}

  @doc """
  Resolves the dbt project folder: the `--project-dir` flag, then the
  `BARD_PROJECT_DIR` environment variable, then the current folder.
  Relative paths are expanded from the current folder.
  """
  @spec project_dir(String.t() | nil) :: Path.t()
  def project_dir(flag) do
    Path.expand(flag || System.get_env("BARD_PROJECT_DIR") || ".")
  end

  @doc "Loads a project from dbt's manifest."
  @spec load_project(keyword()) :: {:ok, Project.t()} | {:error, term()}
  def load_project(opts), do: Project.load(Loader.Manifest, opts)

  @doc """
  Loads a project by compiling its files with Bard (Phase 3).

  `target` is a `Bard.Profile` target. With a connection (`{adapter, conn}`),
  `is_incremental()` sees what is in the warehouse; with `nil`, nothing
  exists yet. Other options go to `Bard.Loader.Files`: `:vars`,
  `:full_refresh`, `:fallback_manifest`, `:compile`.
  """
  @spec compile_project(Path.t(), map(), {module(), term()} | nil, keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def compile_project(project_dir, target, connection, opts \\ []) do
    opts =
      [project_dir: project_dir, target: target, relation_type: relation_type(connection)] ++
        Keyword.take(opts, [:vars, :full_refresh, :fallback_manifest, :compile, :cache])

    Project.load(Loader.Files, opts)
  end

  defp relation_type(nil), do: fn _relation -> nil end

  defp relation_type({adapter, conn}) do
    fn %{database: database, schema: schema, identifier: identifier} ->
      relation = %Relation{database: database, schema: schema, identifier: identifier}

      case adapter.describe(conn, relation) do
        {:ok, %{type: type}} -> type
        _ -> nil
      end
    end
  end

  @doc "The adapter module for a target's `type`."
  @spec adapter(map()) :: {:ok, module()} | {:error, term()}
  def adapter(%{type: type}) do
    case Map.fetch(@adapters, type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_adapter, type}}
    end
  end

  @doc ~S"""
  Parses `--vars`, which dbt reads as YAML: `'{"key": "value"}'` or `'key: value'`.
  """
  @spec parse_vars(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def parse_vars(nil), do: {:ok, %{}}

  def parse_vars(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, %{} = vars} -> {:ok, vars}
      {:ok, _} -> {:error, {:invalid_vars, text}}
      {:error, _} -> {:error, {:invalid_vars, text}}
    end
  end

  @doc "One line per diagnostic, errors first."
  @spec format_diagnostics([Diagnostic.t()]) :: [String.t()]
  def format_diagnostics(diagnostics) do
    diagnostics
    |> Enum.sort_by(&{&1.severity != :error, &1.file || "", &1.line || 0})
    |> Enum.map(&Diagnostic.format/1)
  end

  @doc "Turns a Bard error term into a message for people."
  @spec format_error(term()) :: String.t()
  def format_error({:manifest_not_found, path}),
    do: "No manifest at #{path}. Run `dbt parse` in the dbt project first."

  def format_error({:unsupported_manifest_version, version, supported}),
    do:
      "Manifest schema #{version} is not supported yet (supported: #{Enum.join(supported, ", ")})."

  def format_error({:invalid_manifest, path, reason}),
    do: "Invalid manifest at #{path}: #{inspect(reason)}"

  def format_error({:missing_parents, pairs}) do
    lines = Enum.map_join(pairs, "\n", fn {id, parent} -> "  #{id} -> #{parent}" end)
    "Nodes depend on nodes that are not in the project:\n" <> lines
  end

  def format_error({:cycle, cycles}) do
    lines = Enum.map_join(cycles, "\n", &("  " <> Enum.join(&1, ", ")))
    "The project graph has cycles:\n" <> lines
  end

  def format_error({:invalid_criterion, text}), do: "Invalid selector: #{text}"
  def format_error({:invalid_criterion, text, why}), do: "Invalid selector #{text}: #{why}"

  def format_error({:unsupported_method, method}),
    do: "Selector method not supported yet: #{method}:"

  def format_error(:empty_selector), do: "Empty selector."

  def format_error({:not_compiled, names}),
    do:
      "These models have no compiled SQL: #{Enum.join(names, ", ")}.\n" <>
        "Run `dbt compile --target <target>` with the same target as `bard run`."

  def format_error({:profile_not_found, name, dir}),
    do: "Profile #{name} not found in #{Path.join(dir, "profiles.yml")}."

  def format_error({:target_not_found, name, available}),
    do: "Target #{name} not found. Available targets: #{Enum.join(available, ", ")}."

  def format_error({{:missing_env_var, var}, key}),
    do: "profiles.yml: #{key} uses env_var('#{var}'), but #{var} is not set."

  def format_error({:unsupported_jinja, key}),
    do: "profiles.yml: #{key} uses Jinja that Bard does not render yet (only env_var)."

  def format_error({:yaml_error, path, message}), do: "Could not read #{path}: #{message}"

  def format_error({:unsupported_adapter, type}),
    do: "Adapter type #{type} is not supported yet. Phase 2 supports postgres."

  def format_error({:connection_failed, message}), do: "Could not connect: #{message}"

  def format_error({:diagnostics, diagnostics}) do
    errors = Enum.count(diagnostics, &Diagnostic.error?/1)

    Enum.join(format_diagnostics(diagnostics), "\n") <>
      "\nCompilation failed with #{errors} error(s)."
  end

  def format_error({:invalid_vars, text}),
    do: "--vars must be a YAML or JSON mapping, got: #{text}"

  def format_error(other), do: inspect(other)
end
