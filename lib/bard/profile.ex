defmodule Bard.Profile do
  @moduledoc """
  Resolves the warehouse connection for a dbt project from `profiles.yml`.

  It follows dbt's rules: the profile is named by `profile:` in
  `dbt_project.yml`, and `profiles.yml` is looked up in

    1. the `:profiles_dir` option (`--profiles-dir`)
    2. the `DBT_PROFILES_DIR` environment variable
    3. the project folder, when it holds a `profiles.yml`
    4. `~/.dbt`

  The target is the `:target` option (`--target`), else the profile's
  `target:` default.

  Profiles are Jinja templates, but in practice they only use `env_var`.
  `{{ env_var('NAME') }}` and `{{ env_var('NAME', 'default') }}` are rendered,
  with or without an `| int` or `| as_number` filter. Any other Jinja fails
  with a clear error.
  """

  use Boundary, top_level?: true, deps: [], exports: []

  @type target :: %{
          required(:name) => String.t(),
          required(:profile) => String.t(),
          required(:type) => String.t(),
          optional(atom()) => term()
        }

  @env_var ~r/\{\{\s*env_var\(\s*['"]([^'"]+)['"]\s*(?:,\s*['"]([^'"]*)['"]\s*)?\)\s*(?:\|\s*(?:int|as_number|as_text)\s*)?\}\}/

  @integers ~w(port threads)

  @spec load(Path.t(), keyword()) :: {:ok, target()} | {:error, term()}
  def load(project_dir, opts \\ []) do
    dir = profiles_dir(project_dir, opts[:profiles_dir])

    with {:ok, project} <- read_yaml(Path.join(project_dir, "dbt_project.yml")),
         {:ok, profile_name} <- fetch(project, "profile", :no_profile_in_project),
         {:ok, profiles} <- read_yaml(Path.join(dir, "profiles.yml")),
         {:ok, profile} <- fetch(profiles, profile_name, {:profile_not_found, profile_name, dir}),
         target_name = opts[:target] || profile["target"],
         {:ok, outputs} <- fetch(profile, "outputs", {:no_outputs, profile_name}),
         {:ok, raw} <-
           fetch(outputs, target_name, {:target_not_found, target_name, Map.keys(outputs)}),
         {:ok, rendered} <- render(raw) do
      {:ok, normalize(rendered, profile_name, target_name)}
    end
  end

  @doc false
  @spec profiles_dir(Path.t(), Path.t() | nil) :: Path.t()
  def profiles_dir(project_dir, flag) do
    cond do
      flag -> Path.expand(flag)
      env = System.get_env("DBT_PROFILES_DIR") -> Path.expand(env)
      File.exists?(Path.join(project_dir, "profiles.yml")) -> Path.expand(project_dir)
      true -> Path.expand("~/.dbt")
    end
  end

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, {:invalid_yaml, path}}
      {:error, %{message: message}} -> {:error, {:yaml_error, path, message}}
    end
  end

  defp fetch(map, key, error) do
    case map do
      %{^key => value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp render(target) do
    Enum.reduce_while(target, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case render_value(value) do
        {:ok, rendered} -> {:cont, {:ok, Map.put(acc, key, rendered)}}
        {:error, reason} -> {:halt, {:error, {reason, key}}}
      end
    end)
  end

  defp render_value(value) when is_binary(value) do
    rendered =
      Regex.replace(@env_var, value, fn whole, name, default ->
        case {System.get_env(name), default} do
          {nil, ""} -> throw({:missing_env_var, name, whole})
          {nil, default} -> default
          {set, _} -> set
        end
      end)

    if String.contains?(rendered, "{{") or String.contains?(rendered, "{%"),
      do: {:error, :unsupported_jinja},
      else: {:ok, rendered}
  catch
    {:missing_env_var, name, _whole} -> {:error, {:missing_env_var, name}}
  end

  defp render_value(value), do: {:ok, value}

  defp normalize(target, profile, name) do
    base = %{name: name, profile: profile, raw: target}

    Enum.reduce(target, base, fn {key, value}, acc ->
      key = if key == "database", do: "dbname", else: key
      value = if key in @integers and is_binary(value), do: String.to_integer(value), else: value
      Map.put(acc, String.to_atom(key), value)
    end)
  end
end
