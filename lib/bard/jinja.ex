defmodule Bard.Jinja do
  @moduledoc """
  The subset of Jinja that dbt projects use, in pure Elixir.

      {:ok, ast} = Bard.Jinja.parse("select {{ 1 + 1 }} as two")
      {:ok, "select 2 as two"} = Bard.Jinja.render(ast, %{})

  Behaves like Jinja with dbt's settings: no `trim_blocks`, no
  `lstrip_blocks`, one trailing newline removed, and the `do` and loop-control
  extensions.

  Supported:

    * `{{ expr }}`, `{% tag %}`, `{# comment #}`, whitespace control (`{%-`, `-%}`)
    * `if`/`elif`/`else`, `for` (with `loop.*`, `else`, an `if` filter,
      `break`/`continue`), `set` (single, tuple and block), `macro`, `do`, `raw`
    * literals, lists, dicts, attribute and item access, calls with keyword
      arguments, filters, tests (`is none`, `is defined`, ...), `not`/`and`/`or`,
      comparisons, `in`, arithmetic, `~`, `a if c else b`

  Anything else fails with a `Bard.Jinja.Error` that names the line, so callers
  can fall back instead of producing wrong SQL.

  Values follow Python: `None` renders as `None`, lists as `['a', 'b']`, and
  missing names are undefined (falsy, render as nothing).
  """

  use Boundary, top_level?: true, deps: [], exports: [Error, Macro, Object, Value]

  alias Bard.Jinja.Error
  alias Bard.Jinja.Eval
  alias Bard.Jinja.Lexer
  alias Bard.Jinja.Parser

  @type ast :: [term()]
  @type globals :: %{optional(String.t()) => term()}

  @doc "Parses a template into an AST."
  @spec parse(String.t()) :: {:ok, ast} | {:error, Error.t()}
  def parse(source) when is_binary(source) do
    with {:ok, tokens} <- Lexer.tokenize(source), do: Parser.parse(tokens)
  end

  @doc "Renders a template (source or parsed AST) with the given globals."
  @spec render(String.t() | ast, globals) :: {:ok, String.t()} | {:error, Error.t()}
  def render(source, globals) when is_binary(source) do
    with {:ok, ast} <- parse(source), do: render(ast, globals)
  end

  def render(ast, globals) when is_list(ast) do
    {:ok, ast |> Eval.render(globals) |> IO.iodata_to_binary()}
  rescue
    error in Error -> {:error, error}
  end

  @doc """
  Evaluates a template for its macro definitions (a dbt `macros/*.sql` file)
  and returns them by name. Output outside macros is ignored.
  """
  @spec macros(String.t() | ast) ::
          {:ok, %{String.t() => Bard.Jinja.Macro.t()}} | {:error, Error.t()}
  def macros(source) when is_binary(source) do
    with {:ok, ast} <- parse(source), do: macros(ast)
  end

  def macros(ast) when is_list(ast) do
    {:ok,
     for(
       {:macro, name, params, body, line} <- ast,
       into: %{},
       do: {name, %Bard.Jinja.Macro{name: name, params: params, body: body, line: line}}
     )}
  end

  @doc "Calls a macro from Elixir, as `generate_schema_name(...)` would be called from Jinja."
  @spec call(Bard.Jinja.Macro.t(), [term()], map(), globals) ::
          {:ok, term()} | {:error, Error.t()}
  def call(macro, args, kwargs, globals) do
    {:ok, Eval.call_macro(macro, args, kwargs, globals)}
  rescue
    error in Error -> {:error, error}
  end
end
