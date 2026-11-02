defmodule Bard.Compiler.Diagnostic do
  @moduledoc """
  A problem the compiler found, with a stable code, the file and the line.

  Codes group by area, so they can be documented, searched and silenced:

  | Code    | Severity | Meaning                                                  |
  |---------|----------|----------------------------------------------------------|
  | BARD001 | error    | `dbt_project.yml` not found                              |
  | BARD002 | error    | a YAML file cannot be read or parsed                     |
  | BARD003 | error    | `dbt_project.yml` is missing a required key              |
  | BARD004 | error    | a project setting has the wrong type                     |
  | BARD101 | error    | a config value has the wrong type                        |
  | BARD102 | warning  | an unknown config key (kept; put custom data in `meta`)  |
  | BARD201 | error    | a template cannot be parsed (unsupported Jinja, syntax)  |
  | BARD202 | error    | a template fails while rendering                         |
  | BARD301 | error    | `ref()` names a node that does not exist                 |
  | BARD302 | error    | `source()` names a source that does not exist            |
  | BARD303 | error    | two nodes have the same name                             |
  | BARD401 | warning  | Bard could not compile a node and used dbt's SQL instead |
  """

  @type severity :: :error | :warning

  @type t :: %__MODULE__{
          code: String.t(),
          severity: severity(),
          message: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          unique_id: String.t() | nil
        }

  @enforce_keys [:code, :severity, :message]
  defstruct [:code, :severity, :message, :file, :line, :unique_id]

  @severities %{
    "BARD001" => :error,
    "BARD002" => :error,
    "BARD003" => :error,
    "BARD004" => :error,
    "BARD101" => :error,
    "BARD102" => :warning,
    "BARD201" => :error,
    "BARD202" => :error,
    "BARD301" => :error,
    "BARD302" => :error,
    "BARD303" => :error,
    "BARD401" => :warning
  }

  @doc "Builds a diagnostic; the severity comes from the code."
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(code, message, opts \\ []) do
    %__MODULE__{
      code: code,
      severity: Map.fetch!(@severities, code),
      message: message,
      file: opts[:file],
      line: opts[:line],
      unique_id: opts[:unique_id]
    }
  end

  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{severity: severity}), do: severity == :error

  @doc ~S"""
  One line for people: `models/orders.sql:12: error BARD301: ...`.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = d) do
    location =
      case {d.file, d.line} do
        {nil, _} -> ""
        {file, nil} -> "#{file}: "
        {file, line} -> "#{file}:#{line}: "
      end

    "#{location}#{d.severity} #{d.code}: #{d.message}"
  end
end
