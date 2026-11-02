defmodule Bard.Jinja.Error do
  @moduledoc "A template that cannot be parsed or rendered, with the line it failed on."
  defexception [:message, :line, :reason]

  @type t :: %__MODULE__{message: String.t(), line: pos_integer() | nil, reason: term()}

  def new(reason, message, line), do: %__MODULE__{reason: reason, message: message, line: line}

  @impl true
  def message(%{message: message, line: nil}), do: message
  def message(%{message: message, line: line}), do: "line #{line}: #{message}"
end

defmodule Bard.Jinja.Macro do
  @moduledoc "A `{% macro %}` definition: parameters (with default expressions) and body."
  defstruct [:name, :params, :body, :line]

  @type t :: %__MODULE__{
          name: String.t(),
          params: [{String.t(), term() | nil}],
          body: list(),
          line: pos_integer()
        }
end

defmodule Bard.Jinja.Object do
  @moduledoc """
  A value Elixir hands to templates: attributes, a string form, and an
  optional call. dbt's relations, `target`, `this` and `loop` are objects.

      %Bard.Jinja.Object{
        str: ~s("db"."marts"."orders"),
        attrs: %{"schema" => "marts", "identifier" => "orders"}
      }
  """
  defstruct str: "", attrs: %{}, call: nil

  @type t :: %__MODULE__{
          str: String.t(),
          attrs: %{optional(String.t()) => term()},
          call: nil | ([term()], map() -> term())
        }
end
