defmodule Bard.Compiler.ProjectFile do
  @moduledoc """
  Reads and validates `dbt_project.yml`.

  Strings are rendered as Jinja first (`{{ env_var('X') }}` works, and `var()`
  sees only `--vars`, as in dbt). The known keys are then checked with
  NimbleOptions; anything else is ignored.
  """

  alias Bard.Compiler.Context
  alias Bard.Compiler.Diagnostic
  alias Bard.Compiler.Yaml

  @file_name "dbt_project.yml"

  @type t :: %__MODULE__{
          name: String.t(),
          profile: String.t() | nil,
          model_paths: [String.t()],
          seed_paths: [String.t()],
          macro_paths: [String.t()],
          vars: map(),
          models: map(),
          seeds: map(),
          sources: map(),
          digest: String.t()
        }

  defstruct [
    :name,
    :profile,
    :digest,
    model_paths: ["models"],
    seed_paths: ["seeds"],
    macro_paths: ["macros"],
    vars: %{},
    models: %{},
    seeds: %{},
    sources: %{}
  ]

  @map {:map, :any, :any}
  @map_or_nil {:or, [@map, nil]}
  @paths [type: {:list, :string}]

  @schema NimbleOptions.new!(
            name: [type: :string, required: true],
            profile: [type: {:or, [:string, nil]}],
            version: [type: {:or, [:string, :integer, :float, nil]}],
            "config-version": [type: {:in, [2]}, default: 2],
            "require-dbt-version": [type: :any],
            "model-paths": @paths,
            "seed-paths": @paths,
            "macro-paths": @paths,
            "snapshot-paths": @paths,
            "test-paths": @paths,
            "analysis-paths": @paths,
            "docs-paths": @paths,
            "asset-paths": @paths,
            "target-path": [type: :string],
            "clean-targets": @paths,
            vars: [type: @map_or_nil],
            models: [type: @map_or_nil],
            seeds: [type: @map_or_nil],
            snapshots: [type: @map_or_nil],
            sources: [type: @map_or_nil],
            tests: [type: @map_or_nil],
            data_tests: [type: @map_or_nil],
            quoting: [type: @map_or_nil],
            flags: [type: @map_or_nil],
            dispatch: [type: {:or, [{:list, @map}, nil]}],
            "on-run-start": [type: :any],
            "on-run-end": [type: :any],
            "query-comment": [type: :any]
          )

  # String key => the atom NimbleOptions validates, built at compile time
  # so no atom is created from user input.
  @keys Map.new(Keyword.keys(@schema.schema), &{Atom.to_string(&1), &1})

  @doc """
  Loads `<dir>/dbt_project.yml`. `target` and `cli_vars` are what its
  templates see.
  """
  @spec load(Path.t(), map(), map()) :: {:ok, t()} | {:error, [Diagnostic.t()]}
  def load(dir, target, cli_vars \\ %{}) do
    path = Path.join(dir, @file_name)

    with {:ok, body} <- read(path),
         {:ok, raw} <- Yaml.read(path, @file_name) |> wrap() do
      globals = Context.base(%{target: target, vars: cli_vars, project_name: nil, macros: %{}})

      case Yaml.render(raw, globals, @file_name) do
        {rendered, []} -> validate(rendered, body)
        {_rendered, diags} -> {:error, diags}
      end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         [
           Diagnostic.new("BARD001", "cannot read #{path}: #{:file.format_error(reason)}",
             file: @file_name
           )
         ]}
    end
  end

  defp wrap({:ok, _} = ok), do: ok
  defp wrap({:error, diag}), do: {:error, [diag]}

  defp validate(raw, body) do
    opts = for {key, value} <- raw, atom = @keys[key], do: {atom, value}

    case NimbleOptions.validate(opts, @schema) do
      {:ok, opts} ->
        {:ok,
         %__MODULE__{
           name: opts[:name],
           profile: opts[:profile],
           model_paths: opts[:"model-paths"] || ["models"],
           seed_paths: opts[:"seed-paths"] || ["seeds"],
           macro_paths: opts[:"macro-paths"] || ["macros"],
           vars: opts[:vars] || %{},
           models: opts[:models] || %{},
           seeds: opts[:seeds] || %{},
           sources: opts[:sources] || %{},
           digest: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
         }}

      {:error, %NimbleOptions.ValidationError{message: message}} ->
        code = if message =~ "required", do: "BARD003", else: "BARD004"
        {:error, [Diagnostic.new(code, message, file: @file_name)]}
    end
  end

  @doc """
  The vars a project's templates see: global project vars, then vars scoped
  to this project (`vars: {my_project: {...}}`), then `--vars`.
  """
  @spec vars(t(), map()) :: map()
  def vars(%__MODULE__{name: name, vars: vars}, cli_vars) do
    {scoped, global} = Map.pop(vars, name)

    global
    |> Map.merge(if is_map(scoped), do: scoped, else: %{})
    |> Map.merge(cli_vars)
  end
end
