defmodule Bard.Compiler.Context do
  @moduledoc """
  The names a dbt template can use: `ref`, `source`, `config`, `var`,
  `env_var`, `is_incremental`, `this`, `target`, `return`, `log`,
  `exceptions`, `execute`, `model`, and the project's own macros.

  Templates are rendered twice, like dbt does:

    * **parse** (`execute` is false): `ref`, `source` and `config` only
      *record* their arguments, so the compiler learns each model's
      dependencies and config without knowing any relation yet.
      `is_incremental()` is false.
    * **compile** (`execute` is true): `ref` and `source` return real
      relations, a `ref` to an ephemeral model returns its CTE name
      (`__dbt__cte__<identifier>`), and `is_incremental()` asks the warehouse.

  Recorded calls go to the process dictionary of the process rendering the
  template. Each file renders in its own task, so recordings never mix;
  `recorded/0` collects them.
  """

  alias Bard.Jinja.Error
  alias Bard.Jinja.Object

  @calls :bard_compiler_calls
  @env :bard_compiler_env_vars

  @typedoc """
  What every template sees:

    * `:target` - a resolved `Bard.Profile` target
    * `:vars` - project vars merged with `--vars` overrides
    * `:project_name`
    * `:macros` - the project's macros by name
  """
  @type env :: %{
          target: map(),
          vars: map(),
          project_name: String.t(),
          macros: map()
        }

  @doc "Starts a fresh recording in the calling process."
  @spec start_recording() :: :ok
  def start_recording do
    Process.put(@calls, [])
    Process.put(@env, %{})
    :ok
  end

  @doc """
  What templates rendered in this process called since `start_recording/0`:
  `{:ref, package | nil, name}`, `{:source, source, table}`,
  `{:config, map}` and `{:ephemeral, unique_id}`, in call order, plus the
  environment variables read (name => value or nil).
  """
  @spec recorded() :: {[tuple()], %{String.t() => String.t() | nil}}
  def recorded do
    {Enum.reverse(Process.get(@calls, [])), Process.get(@env, %{})}
  end

  defp record(call), do: Process.put(@calls, [call | Process.get(@calls, [])])

  @doc """
  Globals for files outside models (`dbt_project.yml`, `schema.yml`):
  `target`, `env_var`, `var`, plus the helpers.
  """
  @spec base(env()) :: map()
  def base(env) do
    Map.merge(env.macros, %{
      "target" => target(env.target),
      "env_var" => &env_var/2,
      "var" => var_fun(env.vars),
      "return" => fn [value], _ -> throw({:jinja_return, value}) end,
      "log" => fn _args, _kwargs -> "" end,
      "print" => fn _args, _kwargs -> "" end,
      "exceptions" => %Object{
        str: "<exceptions>",
        attrs: %{
          "raise_compiler_error" => fn [message | _], _ ->
            raise Error.new({:compiler_error, message}, "compiler error: #{message}", nil)
          end,
          "warn" => fn _args, _kwargs -> "" end
        }
      },
      "project_name" => env.project_name,
      "execute" => false
    })
  end

  @doc """
  Globals for parsing a model: calls are recorded, relations are placeholders.
  `config` is the config known before the file runs (project and properties).
  """
  @spec parse(env(), map(), map()) :: map()
  def parse(env, model, config) do
    Map.merge(base(env), %{
      "ref" => fn args, kwargs ->
        record(ref_call(args, kwargs))
        placeholder()
      end,
      "source" => fn [source, table], _ ->
        record({:source, source, table})
        placeholder()
      end,
      "config" => config_object(config, &record({:config, &1})),
      "is_incremental" => fn [], _ -> false end,
      "this" => placeholder(),
      "model" => model_object(model, config),
      "execute" => false
    })
  end

  @typedoc """
  What compiling a model needs besides `env`:

    * `:resolve_ref` - `(package | nil, name) -> {:ok, node_info} | :error`,
      where node_info has `:unique_id`, `:relation`, `:ephemeral?`, `:identifier`
    * `:resolve_source` - `(source, table) -> {:ok, relation} | :error`
    * `:this` - the model's own relation (nil for ephemeral models)
    * `:config` - the model's resolved config (string keys)
    * `:incremental?` - what `is_incremental()` returns
  """
  @type compile_env :: %{
          resolve_ref: function(),
          resolve_source: function(),
          this: map() | nil,
          config: map(),
          incremental?: boolean()
        }

  @doc "Globals for compiling a model: real relations, ephemeral refs as CTE names."
  @spec compile(env(), map(), compile_env()) :: map()
  def compile(env, model, cenv) do
    Map.merge(base(env), %{
      "ref" => fn args, kwargs ->
        {:ref, package, name} = ref_call(args, kwargs)

        case cenv.resolve_ref.(package, name) do
          {:ok, %{ephemeral?: true} = info} ->
            record({:ephemeral, info.unique_id})
            cte = "__dbt__cte__" <> info.identifier
            %Object{str: cte, attrs: %{"identifier" => cte, "name" => cte}}

          {:ok, info} ->
            relation(info.relation)

          :error ->
            raise Error.new({:ref_not_found, package, name}, "ref('#{name}') not found", nil)
        end
      end,
      "source" => fn [source, table], _ ->
        case cenv.resolve_source.(source, table) do
          {:ok, rel} ->
            relation(rel)

          :error ->
            raise Error.new(
                    {:source_not_found, source, table},
                    "source('#{source}', '#{table}') not found",
                    nil
                  )
        end
      end,
      "config" => config_object(cenv.config, fn _ -> :ok end),
      "is_incremental" => fn [], _ -> cenv.incremental? end,
      "this" => if(cenv.this, do: relation(cenv.this), else: placeholder()),
      "model" => model_object(model, cenv.config),
      "execute" => true
    })
  end

  defp ref_call([name], kwargs), do: {:ref, kwargs["package"], name}
  defp ref_call([package, name], _kwargs), do: {:ref, package, name}

  defp ref_call(args, _kwargs),
    do: raise(Error.new(:bad_ref, "ref() takes 1 or 2 arguments, got #{length(args)}", nil))

  # dbt's `config` is both callable (`config(materialized='table')`) and an
  # object (`config.get('materialized')`).
  defp config_object(config, on_call) do
    %Object{
      str: "",
      call: fn
        [], kwargs ->
          on_call.(kwargs)
          ""

        [%{} = map], _ ->
          on_call.(map)
          ""
      end,
      attrs: %{
        "get" => fn
          [key], %{"default" => default} -> Map.get(config, key, default)
          [key], _ -> Map.get(config, key)
          [key, default], _ -> Map.get(config, key, default)
        end,
        "require" => fn [key], _ ->
          case Map.fetch(config, key) do
            {:ok, value} -> value
            :error -> raise Error.new({:missing_config, key}, "config `#{key}` is required", nil)
          end
        end
      }
    }
  end

  @doc "A relation as templates see it: prints quoted, exposes its parts."
  @spec relation(%{database: String.t() | nil, schema: String.t(), identifier: String.t()}) ::
          Object.t()
  def relation(%{database: database, schema: schema, identifier: identifier}) do
    %Object{
      str: quoted([database, schema, identifier]),
      attrs: %{
        "database" => database,
        "schema" => schema,
        "identifier" => identifier,
        "name" => identifier,
        "table" => identifier
      }
    }
  end

  @doc ~S|Quotes and joins relation parts: `"db"."schema"."name"`.|
  @spec quoted([String.t() | nil]) :: String.t()
  def quoted(parts) do
    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", &(~s(") <> String.replace(&1, ~s("), ~s("")) <> ~s(")))
  end

  defp placeholder, do: %Object{str: "", attrs: %{}}

  defp model_object(model, config) do
    %Object{
      str: model[:name] || "",
      attrs: %{
        "name" => model[:name],
        "unique_id" => model[:unique_id],
        "resource_type" => model[:resource_type] && to_string(model[:resource_type]),
        "package_name" => model[:package],
        "fqn" => model[:fqn],
        "original_file_path" => model[:original_file_path],
        "config" => config
      }
    }
  end

  @doc "`target` as templates see it: dbt's field names, `database` included."
  @spec target(map()) :: map()
  def target(target) do
    %{
      "name" => target[:name],
      "profile_name" => target[:profile],
      "type" => target[:type],
      "schema" => target[:schema],
      "database" => target[:dbname],
      "dbname" => target[:dbname],
      "host" => target[:host],
      "port" => target[:port],
      "user" => target[:user],
      "threads" => target[:threads]
    }
  end

  defp env_var([name | rest], _kwargs) do
    value = System.get_env(name)
    Process.put(@env, Map.put(Process.get(@env, %{}), name, value))

    case {value, rest} do
      {nil, [default | _]} ->
        default

      {nil, []} ->
        raise Error.new(
                {:missing_env_var, name},
                "env var `#{name}` is required but not set",
                nil
              )

      {value, _} ->
        value
    end
  end

  defp var_fun(vars) do
    fn
      [name], _ ->
        case Map.fetch(vars, name) do
          {:ok, value} -> value
          :error -> raise Error.new({:missing_var, name}, "required var `#{name}` not found", nil)
        end

      [name, default | _], _ ->
        Map.get(vars, name, default)
    end
  end
end
