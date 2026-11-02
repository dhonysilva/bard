defmodule Bard.Compiler do
  @moduledoc """
  Bard's own reader for dbt projects: finds the project's files, reads its
  YAML and renders the Jinja inside it, reporting problems as
  `Bard.Compiler.Diagnostic`s.
  """

  use Boundary, top_level?: true, deps: [Bard, Bard.Jinja], exports: [Diagnostic, Files, Yaml]
end
