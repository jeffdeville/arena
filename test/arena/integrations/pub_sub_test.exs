defmodule Arena.Integrations.PubSubTest do
  use ExUnit.Case, async: true

  alias Arena.Config
  alias Arena.Integrations.PubSub

  describe "setup/2" do
    # Phoenix.PubSub is now an optional dep, so the integration can be tested for real.
    test "starts a per-test PubSub server and stores its name at :pubsub_name" do
      config = Arena.setup(%{module: __MODULE__, test: :starts}) |> PubSub.setup()

      name = Config.get(config, :pubsub_name)
      assert is_atom(name) and name != nil
      assert is_pid(Process.whereis(name)), "the per-test PubSub server must be running"
    end

    test "accepts a custom :name" do
      config =
        Arena.setup(%{module: __MODULE__, test: :custom})
        |> PubSub.setup(name: :arena_pubsub_custom_name)

      assert Config.get(config, :pubsub_name) == :arena_pubsub_custom_name
      assert is_pid(Process.whereis(:arena_pubsub_custom_name))
    end
  end

  test "module is documented" do
    assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(PubSub)
    assert moduledoc =~ "Integration with Phoenix.PubSub"
  end
end
