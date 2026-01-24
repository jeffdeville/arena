defmodule Arena.Integrations.PubSubTest do
  use ExUnit.Case, async: true

  alias Arena.Config
  alias Arena.Integrations.PubSub

  describe "setup/2" do
    test "raises error when Phoenix.PubSub is not available" do
      # This will raise because we don't have Phoenix.PubSub as a dependency
      assert_raise RuntimeError, ~r/Phoenix.PubSub is not available/, fn ->
        config = Config.new(:my_test)
        PubSub.setup(config)
      end
    end

    # Note: We can't test the actual PubSub integration without adding Phoenix.PubSub
    # as a dependency. In a real project using Arena, you would add Phoenix.PubSub
    # and test this properly.
  end

  test "module is documented" do
    assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(PubSub)
    assert moduledoc =~ "Integration with Phoenix.PubSub"
  end
end
