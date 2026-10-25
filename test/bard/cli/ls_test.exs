defmodule Bard.CLI.LsTest do
  use ExUnit.Case, async: false

  alias Bard.CLI.Ls
  alias Bard.Test.Fixtures

  setup_all do
    %{project: Fixtures.jaffle_shop()}
  end

  test "selector output matches dbt ls", %{project: project} do
    {:ok, lines} = Ls.run(project, select: ["source:ecom+"])

    assert lines == ["jaffle_shop.staging.stg_stores", "source:jaffle_shop.ecom.raw_stores"]
  end

  test "name, path and json outputs", %{project: project} do
    assert {:ok, ["orders"]} =
             Ls.run(project, select: ["orders"], indirect_selection: :empty, output: :name)

    assert {:ok, ["models/marts/orders.sql"]} =
             Ls.run(project, select: ["orders"], indirect_selection: :empty, output: :path)

    {:ok, [json]} = Ls.run(project, select: ["orders"], indirect_selection: :empty, output: :json)

    assert %{"unique_id" => "model.jaffle_shop.orders", "resource_type" => "model"} =
             Jason.decode!(json)
  end

  describe "mix bard.ls" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "prints the selection" do
      Mix.Tasks.Bard.Ls.run([
        "--project-dir",
        Fixtures.jaffle_shop_dir(),
        "-s",
        "+orders",
        "--resource-type",
        "model"
      ])

      lines = for _ <- 1..3, do: assert_received({:mix_shell, :info, [line]}) && line
      refute_received {:mix_shell, :info, _}

      assert lines == [
               "jaffle_shop.marts.orders",
               "jaffle_shop.staging.stg_orders",
               "jaffle_shop.staging.stg_payments"
             ]
    end

    test "explains a missing manifest" do
      assert_raise Mix.Error, ~r/Run `dbt parse`/, fn ->
        Mix.Tasks.Bard.Ls.run(["--project-dir", "/no/such/project"])
      end
    end

    test "rejects unknown flag values" do
      assert_raise Mix.Error, ~r/Invalid --output/, fn ->
        Mix.Tasks.Bard.Ls.run(["--project-dir", Fixtures.jaffle_shop_dir(), "--output", "yaml"])
      end
    end
  end
end
