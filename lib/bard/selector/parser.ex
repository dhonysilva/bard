defmodule Bard.Selector.Parser do
  @moduledoc """
  Parses dbt's node selection syntax into an AST (Abstract Syntax Tree).

  Supported in Phase 1:

    * space-separated criteria are a union: `"orders customers"`
    * comma-separated criteria are an intersection: `"tag:daily,+orders"`
    * graph operators: `+name`, `name+`, `2+name`, `name+1`, `@name`
    * methods: `fqn` (the default), `tag:`, `path:`, `resource_type:`,
      `package:`, `source:`; `*` wildcards in values

  AST:

      {:union, [expr]}
      {:intersection, [expr]}
      {:criterion, %{method: atom, value: String.t(), parents: depth | nil,
                     children: depth | nil, at: boolean}}

  where `depth` is `:infinity` or a non-negative integer.
  """

  @type depth :: :infinity | non_neg_integer()
  @type criterion :: %{
          method: :fqn | :tag | :path | :resource_type | :package | :source,
          value: String.t(),
          parents: depth | nil,
          children: depth | nil,
          at: boolean()
        }

  @type ast :: {:union, [ast]} | {:intersection, [ast]} | {:criterion, criterion}

  @methods %{
    "fqn" => :fqn,
    "tag" => :tag,
    "path" => :path,
    "resource_type" => :resource_type,
    "package" => :package,
    "source" => :source
  }

  @criterion ~r/\A(?<at>@)?(?:(?<pdepth>\d*)(?<plus>\+))?(?<body>[^+@]+?)(?:(?<cplus>\+)(?<cdepth>\d*))?\z/

  @doc """
  Parses one or more selection strings. Several strings (repeated
  `--select` flags) are a union, like spaces within one string.
  """

  @spec parse(String.t() | [String.t()]) :: {:ok, ast} | {:error, term()}
  def parse(input) when is_binary(input), do: parse([input])

  def parse(inputs) when is_list(inputs) do
    inputs
    |> Enum.flat_map(&String.split(&1, ~r/\s+/, trim: true))
    |> case do
      [] ->
        {:error, :empty_selector}

      terms ->
        with {:ok, items} <- map_ok(terms, &parse_intersection/1) do
          {:ok, {:union, items}}
        end
    end
  end

  defp parse_intersection(term) do
    with {:ok, parts} <- map_ok(String.split(term, ","), &parse_criterion/1) do
      case parts do
        [single] -> {:ok, single}
        many -> {:ok, {:intersection, many}}
      end
    end
  end

  defp parse_criterion(""), do: {:error, :empty_criterion}

  defp parse_criterion(text) do
    case Regex.named_captures(@criterion, text) do
      nil ->
        {:error, {:invalid_criterion, text}}

      %{"at" => "@", "plus" => "+"} ->
        {:error, {:invalid_criterion, text, "@ cannot be combined with a leading +"}}

      caps ->
        with {:ok, method, value} <- method_value(caps["body"]) do
          {:ok,
           {:criterion,
            %{
              method: method,
              value: value,
              at: caps["at"] == "@",
              parents: depth(caps["plus"], caps["pdepth"]),
              children: depth(caps["cplus"], caps["cdepth"])
            }}}
        end
    end
  end

  defp method_value(body) do
    case String.split(body, ":", parts: 2) do
      [value] ->
        {:ok, :fqn, value}

      [method, value] ->
        # dbt allows a method modifier such as `config.materialized:`; Bard
        # does not support modifiers yet, so they fail loudly here.
        case Map.fetch(@methods, method) do
          {:ok, atom} when value != "" -> {:ok, atom, value}
          {:ok, _} -> {:error, {:invalid_criterion, body, "missing value"}}
          :error -> {:error, {:unsupported_method, method}}
        end
    end
  end

  defp depth("", _), do: nil
  defp depth("+", ""), do: :infinity
  defp depth("+", digits), do: String.to_integer(digits)

  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
