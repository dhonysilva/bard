defmodule Bard.ProfileTest do
  use ExUnit.Case, async: false

  alias Bard.Profile

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "dbt_project.yml"), "name: shop\nprofile: shop\n")

    File.write!(Path.join(dir, "profiles.yml"), """
    shop:
      target: dev
      outputs:
        dev:
          type: postgres
          host: localhost
          port: "{{ env_var('BARD_TEST_PORT', '5433') | int }}"
          user: "{{ env_var('BARD_TEST_USER') }}"
          password: secret
          dbname: analytics
          schema: dev
          threads: 8
        prod:
          type: postgres
          host: db.internal
          user: "{{ env_var('BARD_TEST_USER') }}"
          password: "{{ secret_manager('x') }}"
          database: analytics
          schema: prod
    """)

    System.put_env("BARD_TEST_USER", "dhony")
    on_exit(fn -> System.delete_env("BARD_TEST_USER") end)
    %{dir: dir}
  end

  test "reads the project's profile and default target, rendering env_var", %{dir: dir} do
    assert {:ok, target} = Profile.load(dir)

    assert %{
             name: "dev",
             profile: "shop",
             type: "postgres",
             user: "dhony",
             port: 5433,
             dbname: "analytics",
             schema: "dev",
             threads: 8
           } = target
  end

  test "picks another target and reports unsupported Jinja", %{dir: dir} do
    assert Profile.load(dir, target: "prod") == {:error, {:unsupported_jinja, "password"}}
    assert {:error, {:target_not_found, "qa", ["dev", "prod"]}} = Profile.load(dir, target: "qa")
  end

  test "fails clearly when an env var is missing", %{dir: dir} do
    System.delete_env("BARD_TEST_USER")
    assert Profile.load(dir) == {:error, {{:missing_env_var, "BARD_TEST_USER"}, "user"}}
  end

  test "follows dbt's lookup order for profiles.yml", %{dir: dir} do
    assert Profile.profiles_dir(dir, "/flag") == "/flag"
    assert Profile.profiles_dir(dir, nil) == dir

    empty = Path.join(dir, "no_profiles_here")
    File.mkdir_p!(empty)
    assert Profile.profiles_dir(empty, nil) == Path.expand("~/.dbt")
  end
end
