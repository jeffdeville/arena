defmodule Arena.CaseTest do
  use ExUnit.Case, async: true

  alias Arena.Config

  defp tags(extra \\ %{}),
    do: Map.merge(%{module: __MODULE__, test: :"t_#{System.unique_integer([:positive])}", async: true}, extra)

  describe "setup_isolation/2" do
    test "builds a per-test config exposed under :config and :arena" do
      {:ok, ctx} = Arena.Case.setup_isolation(tags())

      assert ctx[:config] == ctx[:arena]
      refute ctx[:config].owner == :arena_global
      # stored in this process, so via_tuple/current resolve here
      assert Config.current().owner == ctx[:config].owner
    end

    test "with pubsub: true, starts a per-test server and exposes it" do
      {:ok, ctx} = Arena.Case.setup_isolation(tags(), pubsub: true)

      pubsub = ctx[:pubsub]
      assert is_atom(pubsub) and pubsub != nil
      assert is_pid(Process.whereis(pubsub)), "the per-test PubSub server must be running"
      assert Config.get(ctx[:config], :pubsub_name) == pubsub
    end

    test "without pubsub, no :pubsub key is exposed" do
      {:ok, ctx} = Arena.Case.setup_isolation(tags())
      refute Keyword.has_key?(ctx, :pubsub)
    end

    test "with a :repo but no ecto_sql available, raises a helpful error" do
      assert_raise RuntimeError, ~r/requires `:ecto_sql`/, fn ->
        Arena.Case.setup_isolation(tags(), repo: SomeApp.Repo)
      end
    end
  end

  describe "wrap!/2" do
    test "wraps a real per-test config" do
      config = Arena.setup(tags())
      assert %Arena.Wrapped{config: ^config, input: :state} = Arena.Case.wrap!(config, :state)
    end

    test "raises loudly under the shared :arena_global owner" do
      assert_raise RuntimeError, ~r/:arena_global/, fn ->
        Arena.Case.wrap!(Config.defaults(), :state)
      end
    end
  end
end
