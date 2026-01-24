defmodule Arena.ConfigTest do
  use ExUnit.Case, async: true

  alias Arena.Config

  describe "new/2" do
    test "creates config from atom" do
      config = Config.new(:my_test)

      assert %Config{} = config
      assert config.owner == :my_test
      assert config.id == {:my_test}
      assert config.context == %{}
      assert config.callbacks == []
    end

    test "creates config from test context map" do
      context = %{test: :my_test, module: MyApp.SomeTest}
      config = Config.new(context)

      assert %Config{} = config
      assert is_atom(config.owner)
      # Owner should be based on module and test name
      assert Atom.to_string(config.owner) =~ "MyApp.SomeTest.my_test"
      assert config.id == {config.owner}
    end

    test "accepts context option" do
      config = Config.new(:my_test, context: %{pubsub_name: MyPubSub})

      assert config.context == %{pubsub_name: MyPubSub}
    end

    test "accepts callbacks option" do
      callbacks = [{MyModule, :setup}, {OtherModule, :init, [key: :value]}]
      config = Config.new(:my_test, callbacks: callbacks)

      assert config.callbacks == callbacks
    end
  end

  describe "defaults/0" do
    test "returns global default config" do
      config = Config.defaults()

      assert config.owner == :arena_global
      assert config.id == {:arena_global}
      assert config.context == %{}
      assert config.callbacks == []
    end
  end

  describe "current/0 and store/1" do
    test "returns defaults when nothing stored" do
      # Clean process dictionary
      Process.delete(:arena_config)

      config = Config.current()
      assert config.owner == :arena_global
    end

    test "stores and retrieves config" do
      config = Config.new(:my_test)
      returned = Config.store(config)

      assert returned == config
      assert Config.current() == config
    end
  end

  describe "get/2" do
    test "gets struct field for allowed keys" do
      config = Config.new(:my_test)

      assert Config.get(config, :owner) == :my_test
      assert Config.get(config, :id) == {:my_test}
      assert Config.get(config, :callbacks) == []
    end

    test "gets context value for other keys" do
      config = Config.new(:my_test, context: %{pubsub_name: MyPubSub})

      assert Config.get(config, :pubsub_name) == MyPubSub
    end

    test "raises for missing context key" do
      config = Config.new(:my_test)

      assert_raise KeyError, fn ->
        Config.get(config, :nonexistent)
      end
    end

    test "0-arity version uses current()" do
      config = Config.new(:my_test, context: %{key: :value})
      Config.store(config)

      assert Config.get(:key) == :value
    end
  end

  describe "put/3" do
    test "adds value to context" do
      config = Config.new(:my_test)
      new_config = Config.put(config, :pubsub_name, MyPubSub)

      assert new_config.context == %{pubsub_name: MyPubSub}
    end

    test "raises for protected keys" do
      config = Config.new(:my_test)

      assert_raise ArgumentError, ~r/Cannot manually set protected key/, fn ->
        Config.put(config, :owner, :new_owner)
      end
    end

    test "executes callbacks when putting value" do
      # Use a test process to track callback execution
      parent = self()
      callback = {__MODULE__, :test_callback, [parent: parent]}

      config = Config.new(:my_test, callbacks: [callback])
      Config.put(config, :test_key, :test_value)

      assert_receive {:callback_executed, %Config{}}
    end

    test "1-arity version uses and updates current()" do
      config = Config.new(:my_test)
      Config.store(config)

      Config.put(:key, :value)

      assert Config.current().context == %{key: :value}
    end
  end

  describe "add_callback/2" do
    test "adds 2-tuple callback" do
      config = Config.new(:my_test)
      new_config = Config.add_callback(config, {MyModule, :setup})

      assert new_config.callbacks == [{MyModule, :setup}]
    end

    test "adds 3-tuple callback with opts" do
      config = Config.new(:my_test)
      new_config = Config.add_callback(config, {MyModule, :setup, [key: :value]})

      assert new_config.callbacks == [{MyModule, :setup, [key: :value]}]
    end

    test "appends to existing callbacks" do
      config = Config.new(:my_test, callbacks: [{First, :callback}])
      new_config = Config.add_callback(config, {Second, :callback})

      assert new_config.callbacks == [{First, :callback}, {Second, :callback}]
    end

    test "stores callback automatically" do
      config = Config.new(:my_test)
      Config.store(config)

      Config.add_callback({MyModule, :setup})

      assert Config.current().callbacks == [{MyModule, :setup}]
    end
  end

  describe "execute_callbacks/1" do
    test "executes 2-tuple callbacks" do
      parent = self()
      callback = {__MODULE__, :test_callback, [parent: parent]}

      config = Config.new(:my_test, callbacks: [callback])
      Config.execute_callbacks(config)

      assert_receive {:callback_executed, ^config}
    end

    test "executes multiple callbacks in order" do
      parent = self()

      config = Config.new(:my_test,
        callbacks: [
          {__MODULE__, :test_callback, [parent: parent, id: 1]},
          {__MODULE__, :test_callback, [parent: parent, id: 2]}
        ]
      )

      Config.execute_callbacks(config)

      assert_receive {:callback_executed, %Config{}, 1}
      assert_receive {:callback_executed, %Config{}, 2}
    end
  end

  describe "child/2" do
    test "creates child config with extended id" do
      parent = Config.new(:my_test)
      child = Config.child(parent, MyServer)

      assert child.owner == :my_test
      assert child.id == {:my_test, MyServer}
      assert child.context == parent.context
      assert child.callbacks == parent.callbacks
    end

    test "creates grandchild config" do
      parent = Config.new(:my_test)
      child = Config.child(parent, MyServer)
      grandchild = Config.child(child, :instance_1)

      assert grandchild.id == {:my_test, MyServer, :instance_1}
    end

    test "is idempotent when child_key already last element" do
      parent = Config.new(:my_test)
      child = Config.child(parent, MyServer)
      same_child = Config.child(child, MyServer)

      assert child.id == same_child.id
    end
  end

  describe "root/1" do
    test "returns root owner from config" do
      config = Config.new(:my_test)
      |> Config.child(MyServer)
      |> Config.child(:instance_1)

      assert Config.root(config) == :my_test
    end

    test "0-arity version uses current()" do
      config = Config.new(:my_test)
      |> Config.child(MyServer)

      Config.store(config)

      assert Config.root() == :my_test
    end
  end

  describe "to_string/1" do
    test "converts simple id to string" do
      config = Config.new(:my_test)

      assert Config.to_string(config) == "my_test"
    end

    test "converts hierarchical id to string" do
      config = Config.new(:my_test)
      |> Config.child(MyApp.Server)
      |> Config.child(:instance_1)

      result = Config.to_string(config)
      assert result == "my_test/MyApp.Server/instance_1"
    end

    test "strips Elixir prefix from module names" do
      config = Config.new(:my_test)
      |> Config.child(String)

      result = Config.to_string(config)
      # Should not have "Elixir." prefix
      refute result =~ "Elixir."
    end
  end

  # Helper for testing callbacks
  def test_callback(config, opts \\ []) do
    parent = Keyword.get(opts, :parent)
    id = Keyword.get(opts, :id)

    if parent do
      if id do
        send(parent, {:callback_executed, config, id})
      else
        send(parent, {:callback_executed, config})
      end
    end
  end
end
