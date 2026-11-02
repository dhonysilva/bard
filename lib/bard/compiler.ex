defmodule Bard.Compiler do
  @moduledoc """
  Bard's own dbt compiler: reads a dbt project's files and produces the
  same nodes, relation names and compiled SQL that `dbt compile` does.

      {:ok, project} =
        Bard.Compiler.load(project_dir: "../shop", target: target)

  Steps, in order:

    1. `dbt_project.yml` (`Bard.Compiler.ProjectFile`)
    2. macros (`macros/**/*.sql`), parsed by `Bard.Jinja`
    3. properties files (`Bard.Compiler.Properties`) and sources
    4. **parse**: every model is rendered with recording `ref`/`source`/
       `config` (`Bard.Compiler.Context`), in parallel, with a cache
    5. config (`Bard.Compiler.Config`) and names (`Bard.Compiler.Naming`)
    6. dependencies: refs and sources resolved to unique ids
    7. **compile**: every model is rendered again with real relations,
       in parallel, then ephemeral models are inlined (`Bard.Compiler.Ctes`)

  Problems become `Bard.Compiler.Diagnostic`s. Any error fails the load,
  with all diagnostics; warnings are kept in `project.diagnostics`.

  ## Options

    * `:project_dir` (required)
    * `:target` (required) - a resolved `Bard.Profile` target
    * `:vars` - `--vars` overrides, a map
    * `:compile` - run step 7 (default `true`); `false` is enough for `bard ls`
    * `:relation_type` - `relation -> :table | :view | nil`: what is in the
      warehouse, for `is_incremental()`. Defaults to "nothing exists".
    * `:full_refresh` - makes `is_incremental()` false (default `false`)
    * `:fallback` - nodes compiled by dbt (`unique_id => %Bard.Node{}`). A node
      Bard cannot compile takes dbt's SQL instead, with a BARD401 warning.
    * `:cache` - use `bard_target/parse_cache.etf` (default `true`)
  """

  use Boundary, top_level?: true, deps: [Bard, Bard.Jinja], exports: [Diagnostic]

  alias Bard.Node
  alias Bard.Project

  alias Bard.Compiler.{
    Cache,
    Config,
    Context,
    Ctes,
    Diagnostic,
    Files,
    Naming,
    ProjectFile,
    Properties
  }

  alias Bard.Jinja

  @spec load(keyword()) :: {:ok, Project.t()} | {:error, {:diagnostics, [Diagnostic.t()]}}
  def load(opts) do
    dir = opts |> Keyword.fetch!(:project_dir) |> Path.expand()
    target = Keyword.fetch!(opts, :target)
    cli_vars = Keyword.get(opts, :vars, %{})

    case ProjectFile.load(dir, target, cli_vars) do
      {:ok, pf} -> load(dir, pf, target, cli_vars, opts)
      {:error, diags} -> {:error, {:diagnostics, diags}}
    end
  end

  defp load(dir, pf, target, cli_vars, opts) do
    {macros, macro_files, macro_diags} = macros(dir, pf)

    env = %{
      target: target,
      vars: ProjectFile.vars(pf, cli_vars),
      project_name: pf.name,
      macros: macros
    }

    base = Context.base(env)

    yml = Files.find(dir, pf.model_paths ++ pf.seed_paths, [".yml", ".yaml"])

    {props, prop_diags} =
      Properties.load(Enum.map(yml, &{&1.abs, &1.original_file_path, &1.dirs}), base)

    models = Files.find(dir, pf.model_paths, [".sql"]) |> Enum.map(&model(&1, pf, props))
    seeds = Files.find(dir, pf.seed_paths, [".csv"]) |> Enum.map(&seed(&1, pf, props))

    fingerprint =
      Cache.hash({pf.digest, macro_files, env.vars, Map.drop(target, [:password, :raw])})

    {models, parse_diags} = parse(models, env, dir, fingerprint, opts)

    {models, config_diags} = resolve_config(models)
    {seeds, seed_diags} = resolve_config(seeds)
    {nodes, name_diags} = name(models ++ seeds, target, base)
    {sources, source_diags} = sources(props.sources, pf, target)

    dup_diags = duplicates(nodes)
    {nodes, dep_diags} = depend(nodes, sources, pf.name)

    {nodes, compile_diags} =
      if Keyword.get(opts, :compile, true),
        do: compile(nodes, sources, env, opts),
        else: {nodes, []}

    diags =
      (macro_diags ++ prop_diags ++ parse_diags ++ config_diags ++ seed_diags ++ name_diags) ++
        source_diags ++ dup_diags ++ dep_diags ++ compile_diags

    {nodes, diags} = fallback(nodes, diags, opts[:fallback] || %{})
    diags = dedupe(diags)

    if Enum.any?(diags, &Diagnostic.error?/1) do
      {:error, {:diagnostics, diags}}
    else
      project_nodes = Enum.map(nodes, &to_node/1) ++ Enum.map(sources, &source_node/1)

      {:ok,
       %Project{
         name: pf.name,
         root: dir,
         schema_version: "bard",
         nodes: Map.new(project_nodes, &{&1.unique_id, &1}),
         diagnostics: diags
       }}
    end
  end

  defp macros(dir, pf) do
    files = Files.find(dir, pf.macro_paths, [".sql"])

    Enum.reduce(files, {%{}, [], []}, fn file, {macros, hashes, diags} ->
      source = Files.read!(file)
      hashes = [{file.original_file_path, Cache.hash(source)} | hashes]

      case Jinja.macros(source) do
        {:ok, found} ->
          {Map.merge(macros, found), hashes, diags}

        {:error, error} ->
          {macros, hashes, [jinja_diag("BARD201", error, file.original_file_path, nil) | diags]}
      end
    end)
    |> then(fn {macros, hashes, diags} -> {macros, Enum.sort(hashes), Enum.reverse(diags)} end)
  end

  defp model(file, pf, props) do
    raw = Files.read!(file)
    fqn = [pf.name | file.dirs] ++ [file.name]
    patch = props.models[file.name]

    %{
      unique_id: "model.#{pf.name}.#{file.name}",
      resource_type: :model,
      name: file.name,
      package: pf.name,
      fqn: fqn,
      path: file.path,
      original_file_path: file.original_file_path,
      raw_code: raw,
      checksum: Cache.hash(raw),
      # Config known before the file runs: defaults, project tree, properties.
      config:
        %{"materialized" => "view"}
        |> Config.merge(Config.from_tree(pf.models, fqn))
        |> Config.merge((patch && patch.config) || %{}),
      columns: (patch && patch.columns) || %{},
      calls: [],
      error: nil
    }
  end

  defp seed(file, pf, props) do
    fqn = [pf.name | file.dirs] ++ [file.name]
    patch = props.seeds[file.name]

    %{
      unique_id: "seed.#{pf.name}.#{file.name}",
      resource_type: :seed,
      name: file.name,
      package: pf.name,
      fqn: fqn,
      path: file.path,
      original_file_path: file.original_file_path,
      raw_code: nil,
      checksum: file |> Files.read!() |> Cache.hash(),
      config:
        %{"materialized" => "seed"}
        |> Config.merge(Config.from_tree(pf.seeds, fqn))
        |> Config.merge((patch && patch.config) || %{}),
      columns: (patch && patch.columns) || %{},
      calls: [],
      error: nil
    }
  end

  defp parse(models, env, dir, fingerprint, opts) do
    use_cache? = Keyword.get(opts, :cache, true)
    cache_file = Cache.path(dir)
    cache = if use_cache?, do: Cache.load(cache_file, fingerprint), else: %{}

    results =
      models
      |> Task.async_stream(
        fn model ->
          key = Cache.hash({model.checksum, model.config})

          case Cache.fetch(cache, model.original_file_path, key) do
            {:ok, result} -> {model, key, :cached, result}
            :error -> {model, key, :fresh, parse_one(model, env)}
          end
        end,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, result} -> result end)

    if use_cache? do
      entries =
        for {model, key, _, {result, env_used}} <- results, into: %{} do
          {model.original_file_path, {key, env_used, {result, env_used}}}
        end

      Cache.save(cache_file, fingerprint, entries)
    end

    Enum.map_reduce(results, [], fn {model, _key, _, {result, _env}}, diags ->
      case result do
        {:ok, calls} -> {%{model | calls: calls}, diags}
        {:error, diag} -> {%{model | error: diag}, diags ++ [diag]}
      end
    end)
  end

  # Renders a model with recording globals; returns its calls and the env
  # vars it read.
  defp parse_one(model, env) do
    Context.start_recording()
    globals = Context.parse(env, model, model.config)

    result =
      case render(model.raw_code, globals, model) do
        {:ok, _sql} -> {:ok, elem(Context.recorded(), 0)}
        {:error, diag} -> {:error, diag}
      end

    {result, elem(Context.recorded(), 1)}
  end

  defp render(source, globals, node) do
    case Jinja.parse(source) do
      {:ok, ast} ->
        try do
          case Jinja.render(ast, globals) do
            {:ok, sql} -> {:ok, sql}
            {:error, error} -> {:error, jinja_diag(render_code(error), error, node)}
          end
        catch
          kind, reason ->
            message = "unexpected #{kind}: #{inspect(reason)}"
            {:error, Diagnostic.new("BARD202", message, location(node, nil))}
        end

      {:error, error} ->
        {:error, jinja_diag("BARD201", error, node)}
    end
  end

  defp render_code(%Jinja.Error{reason: {:ref_not_found, _, _}}), do: "BARD301"
  defp render_code(%Jinja.Error{reason: {:source_not_found, _, _}}), do: "BARD302"
  defp render_code(_error), do: "BARD202"

  defp jinja_diag(code, error, node),
    do: Diagnostic.new(code, error.message, location(node, error.line))

  defp jinja_diag(code, error, file, line),
    do: Diagnostic.new(code, error.message, file: file, line: line || error.line)

  defp location(node, line),
    do: [file: node.original_file_path, line: line, unique_id: node.unique_id]

  defp resolve_config(nodes) do
    Enum.flat_map_reduce(nodes, [], fn node, diags ->
      config =
        Enum.reduce(node.calls, node.config, fn
          {:config, map}, acc -> Config.merge(acc, map)
          _, acc -> acc
        end)

      {validated, config_diags} = Config.validate(config, location(node, nil))
      node = Map.merge(node, %{config: config, validated: validated})

      # Disabled nodes are left out, as dbt leaves them out of the manifest.
      if validated.enabled == false,
        do: {[], diags ++ config_diags},
        else: {[node], diags ++ config_diags}
    end)
  end

  defp name(nodes, target, base) do
    Enum.map_reduce(nodes, [], fn node, diags ->
      case Naming.relation(node, target, base) do
        {:ok, relation} ->
          {Map.put(node, :relation, relation), diags}

        {:error, error} ->
          diag = jinja_diag("BARD202", error, node)
          {Map.merge(node, %{relation: nil, error: node.error || diag}), diags ++ [diag]}
      end
    end)
  end

  defp ephemeral?(node), do: node.config["materialized"] == "ephemeral"

  defp relation_name(%{relation: nil}), do: nil

  defp relation_name(node),
    do: if(ephemeral?(node), do: nil, else: Naming.relation_name(node.relation))

  defp sources(tables, pf, target) do
    Enum.map_reduce(tables, [], fn table, diags ->
      fqn = [pf.name | table.dirs] ++ [table.source_name, table.name]

      config =
        Config.from_tree(pf.sources, [pf.name, table.source_name, table.name])
        |> Config.merge(table.config)

      unique_id = "source.#{pf.name}.#{table.source_name}.#{table.name}"
      {validated, config_diags} = Config.validate(config, file: table.file, unique_id: unique_id)

      relation = %{
        database: table.database || target[:dbname],
        schema: table.schema,
        identifier: table.identifier
      }

      source =
        Map.merge(table, %{
          unique_id: unique_id,
          package: pf.name,
          fqn: fqn,
          relation: relation,
          validated: validated
        })

      {source, diags ++ config_diags}
    end)
  end

  defp duplicates(nodes) do
    nodes
    |> Enum.group_by(& &1.name)
    |> Enum.filter(fn {_name, group} -> length(group) > 1 end)
    |> Enum.map(fn {name, group} ->
      files = Enum.map_join(group, ", ", & &1.original_file_path)
      Diagnostic.new("BARD303", "`#{name}` is defined more than once: #{files}")
    end)
  end

  defp depend(nodes, sources, project_name) do
    by_name = Map.new(nodes, &{{&1.package, &1.name}, &1.unique_id})
    by_source = Map.new(sources, &{{&1.source_name, &1.name}, &1.unique_id})

    Enum.map_reduce(nodes, [], fn node, diags ->
      {deps, dep_diags} =
        Enum.flat_map_reduce(node.calls, [], fn
          {:ref, package, name}, acc ->
            case Map.fetch(by_name, {package || project_name, name}) do
              {:ok, id} ->
                {[id], acc}

              :error ->
                {[],
                 acc ++
                   [Diagnostic.new("BARD301", "ref('#{name}') not found", location(node, nil))]}
            end

          {:source, source, table}, acc ->
            case Map.fetch(by_source, {source, table}) do
              {:ok, id} ->
                {[id], acc}

              :error ->
                message = "source('#{source}', '#{table}') not found"
                {[], acc ++ [Diagnostic.new("BARD302", message, location(node, nil))]}
            end

          _call, acc ->
            {[], acc}
        end)

      node = Map.merge(node, %{depends_on: deps |> Enum.uniq() |> Enum.sort()})

      node =
        if dep_diags != [] and node.error == nil, do: %{node | error: hd(dep_diags)}, else: node

      {node, diags ++ dep_diags}
    end)
  end

  defp compile(nodes, sources, env, opts) do
    by_name = Map.new(nodes, &{{&1.package, &1.name}, &1})
    by_source = Map.new(sources, &{{&1.source_name, &1.name}, &1.relation})
    relation_type = Keyword.get(opts, :relation_type, fn _ -> nil end)
    full_refresh = Keyword.get(opts, :full_refresh, false)

    resolve_ref = fn package, name ->
      case Map.fetch(by_name, {package || env.project_name, name}) do
        {:ok, node} ->
          {:ok,
           %{
             unique_id: node.unique_id,
             relation: node.relation,
             ephemeral?: ephemeral?(node),
             identifier: node.relation && node.relation.identifier
           }}

        :error ->
          :error
      end
    end

    resolve_source = &Map.fetch(by_source, {&1, &2})

    rendered =
      nodes
      |> Task.async_stream(
        fn
          %{resource_type: :model, error: nil} = node ->
            cenv = %{
              resolve_ref: resolve_ref,
              resolve_source: resolve_source,
              this: if(ephemeral?(node), do: nil, else: node.relation),
              config: node.config,
              incremental?: incremental?(node, relation_type, full_refresh)
            }

            Context.start_recording()

            case render(node.raw_code, Context.compile(env, node, cenv), node) do
              {:ok, sql} ->
                ephemerals =
                  for {:ephemeral, id} <- elem(Context.recorded(), 0), uniq: true, do: id

                {node.unique_id, {:ok, sql, ephemerals}}

              {:error, diag} ->
                {node.unique_id, {:error, diag}}
            end

          node ->
            {node.unique_id, :skip}
        end,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, pair} -> pair end)

    ephemerals = for {id, {:ok, _sql, ephs}} <- rendered, into: %{}, do: {id, ephs}

    info =
      for node <- nodes,
          ephemeral?(node),
          match?({:ok, _, _}, rendered[node.unique_id]),
          into: %{} do
        {:ok, sql, _} = rendered[node.unique_id]
        {node.unique_id, {node.relation.identifier, sql}}
      end

    Enum.map_reduce(nodes, [], fn node, diags ->
      case rendered[node.unique_id] do
        {:ok, sql, _} ->
          missing = Enum.reject(Map.get(ephemerals, node.unique_id, []), &Map.has_key?(info, &1))

          if missing == [] do
            ctes = Ctes.collect(node.unique_id, ephemerals, info)
            {Map.merge(node, %{compiled_code: Ctes.inject(sql, ctes)}), diags}
          else
            message = "ephemeral model #{Enum.join(missing, ", ")} failed to compile"
            diag = Diagnostic.new("BARD202", message, location(node, nil))
            {Map.put(node, :error, diag), diags ++ [diag]}
          end

        {:error, diag} ->
          {Map.put(node, :error, diag), diags ++ [diag]}

        :skip ->
          {node, diags}
      end
    end)
  end

  # dbt's is_incremental(): an incremental model whose table exists, unless
  # this is a full refresh. A model's `full_refresh` config beats the flag.
  defp incremental?(node, relation_type, full_refresh_flag) do
    full_refresh =
      case node.config["full_refresh"] do
        nil -> full_refresh_flag
        value -> value
      end

    node.config["materialized"] == "incremental" and not full_refresh and
      relation_type.(node.relation) == :table
  end

  # A node with an error takes dbt's compiled SQL when the fallback has it;
  # its errors become one BARD401 warning.
  defp fallback(nodes, diags, fallback) when map_size(fallback) == 0, do: {nodes, diags}

  defp fallback(nodes, diags, fallback) do
    Enum.reduce(nodes, {[], diags}, fn node, {acc, diags} ->
      with %{error: %Diagnostic{} = error} <- node,
           %Node{compiled_code: sql} = dbt when is_binary(sql) <- fallback[node.unique_id] do
        own = Enum.filter(diags, &(&1.unique_id == node.unique_id and Diagnostic.error?(&1)))

        warning =
          Diagnostic.new("BARD401", "compiled by dbt instead: #{error.code} #{error.message}",
            file: node.original_file_path,
            line: error.line,
            unique_id: node.unique_id
          )

        node =
          Map.merge(node, %{
            compiled_code: sql,
            compiled_by: :dbt,
            depends_on: if(node.calls == [], do: dbt.depends_on, else: node.depends_on),
            error: nil
          })

        {[node | acc], (diags -- own) ++ [warning]}
      else
        _ -> {[node | acc], diags}
      end
    end)
    |> then(fn {nodes, diags} -> {Enum.reverse(nodes), diags} end)
  end

  defp dedupe(diags), do: Enum.uniq_by(diags, &{&1.code, &1.message, &1.file, &1.line})

  defp to_node(node) do
    %Node{
      unique_id: node.unique_id,
      resource_type: node.resource_type,
      name: node.name,
      package: node.package,
      fqn: node.fqn,
      path: node.path,
      original_file_path: node.original_file_path,
      raw_code: node.raw_code,
      compiled_code: node[:compiled_code],
      compiled_by: Map.get(node, :compiled_by, node[:compiled_code] && :bard),
      relation_name: relation_name(node),
      checksum: node.checksum,
      depends_on: node[:depends_on] || [],
      config: node.validated,
      columns: node.columns
    }
  end

  defp source_node(source) do
    %Node{
      unique_id: source.unique_id,
      resource_type: :source,
      name: source.name,
      package: source.package,
      source_name: source.source_name,
      fqn: source.fqn,
      path: source.file,
      original_file_path: source.file,
      relation_name: Naming.relation_name(source.relation),
      config: source.validated,
      columns: source.columns
    }
  end
end
