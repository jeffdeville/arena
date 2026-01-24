defmodule Arena.Integrations.EctoTest do
  use ExUnit.Case, async: true

  alias Arena.Config
  alias Arena.Integrations.Ecto, as: EctoIntegration

  describe "setup/2" do
    test "raises error when Ecto.Adapters.SQL.Sandbox is not available" do
      # This will raise because we don't have Ecto as a dependency
      assert_raise RuntimeError, ~r/Ecto.Adapters.SQL.Sandbox is not available/, fn ->
        config = Config.new(:my_test)
        EctoIntegration.setup(config, repo: SomeRepo)
      end
    end

    # Note: We can't test the actual Ecto integration without adding Ecto as a dependency.
    # In a real project using Arena, you would add Ecto and test this properly.
    # For now, we just verify that the function exists and raises appropriately.
  end

  describe "allow_sandbox/2" do
    test "does nothing when Ecto is not available" do
      config = Config.new(:my_test)

      # Should not raise, just silently skip
      assert :ok = EctoIntegration.allow_sandbox(config, repo: SomeRepo, ancestor_pid: self())
    end
  end

  test "module is documented" do
    assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(EctoIntegration)
    assert moduledoc =~ "Integration with Ecto.Adapters.SQL.Sandbox"
  end
end
