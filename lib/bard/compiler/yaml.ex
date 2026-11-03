defmodule Bard.Compiler.Yaml do
  @moduledoc """
  Reads dbt's YAML files and renders the Jinja inside their strings.

  dbt renders most YAML values as templates (`schema: "{{ target.schema }}_raw"`),
  but not descriptions, tests or hooks: those are rendered later, or never.
  Only strings containing `{{` or `{%` are rendered, so plain values keep
  their YAML type.
  """

  alias Bard.Compiler.Diagnostic
  alias Bard.Jinja

  # Values under these keys are kept as written.
  @raw_keys ~w(description tests data_tests vars pre-hook post-hook +pre-hook +post-hook
                 on-run-start on-run-end docs)

  @doc "Reads a YAML file into a map. `file` is the path shown in diagnostics."
  @spec read(Path.t(), String.t()) :: {:ok, map()} | {:error, Diagnostic.t()}
  def read(path, file) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = map} ->
        {:ok, map}

      # An empty file.
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, other} when other == [] or other == "" ->
        {:ok, %{}}

      {:ok, _other} ->
        {:error, Diagnostic.new("BARD002", "expected a mapping at the top level", file: file)}

      # YamlElixir returns FileNotFoundError or ParsingError here.
      {:error, error} ->
        message = Exception.message(error)
        {:error, Diagnostic.new("BARD002", "invalid YAML: #{message}", file: file)}
    end
  end

  @doc """
  Renders every templated string in `data` with `globals`. Returns the
  rendered data and a diagnostic per string that failed (left unrendered).
  """
  @spec render(term(), map(), String.t()) :: {term(), [Diagnostic.t()]}
  def render(data, globals, file) do
    {data, diags} = walk(data, globals, file, [])
    {data, Enum.reverse(diags)}
  end

  defp walk(%{} = map, globals, file, diags) do
    Enum.reduce(map, {%{}, diags}, fn {key, value}, {acc, diags} ->
      {value, diags} =
        if key in @raw_keys, do: {value, diags}, else: walk(value, globals, file, diags)

      {Map.put(acc, key, value), diags}
    end)
  end

  defp walk(list, globals, file, diags) when is_list(list) do
    {items, diags} =
      Enum.reduce(list, {[], diags}, fn item, {acc, diags} ->
        {item, diags} = walk(item, globals, file, diags)
        {[item | acc], diags}
      end)

    {Enum.reverse(items), diags}
  end

  defp walk(string, globals, file, diags) when is_binary(string) do
    if String.contains?(string, "{{") or String.contains?(string, "{%") do
      with {:parse, {:ok, ast}} <- {:parse, Jinja.parse(string)},
           {:render, {:ok, rendered}} <- {:render, Jinja.render(ast, globals)} do
        {rendered, diags}
      else
        {stage, {:error, error}} ->
          code = if stage == :parse, do: "BARD201", else: "BARD202"
          {string, [Diagnostic.new(code, Exception.message(error), file: file) | diags]}
      end
    else
      {string, diags}
    end
  end

  defp walk(other, _globals, _file, diags), do: {other, diags}
end
