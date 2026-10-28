defmodule Bard.MixProject do
  use Mix.Project

  def project do
    [
      app: :bard,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Boundary checks module dependencies at compile time.
      compilers: [:boundary] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:jason, "~> 1.4"},
      {:libgraph, "~> 0.16"},
      {:telemetry, "~> 1.2"},
      {:postgrex, "~> 0.19"},
      {:yaml_elixir, "~> 2.9"},
      {:boundary, "~> 0.10", runtime: false}
    ]
  end
end
