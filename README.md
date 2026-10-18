# Bard

Config → Node → Graph → Project → Loader → Loader.Manifest
                                       ↘
           Selector.Parser → Selector → CLI → CLI.Ls → mix bard.ls → Parity


```
iex -S mix
```

```
Bard.Project.load(Bard.Loader.Manifest, project_dir: "test/fixtures/jaffle_shop")
```

Return a project with its graph built.

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `bard` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bard, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/bard>.
