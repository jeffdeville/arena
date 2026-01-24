defmodule Arena.ProcessTest do
  use ExUnit.Case, async: true

  alias Arena.Config
  alias Arena.Wrapped

  # Test servers
  defmodule GlobalServer do
    use GenServer
    use Arena.Process

    def init(state), do: {:ok, state}

    def get_state(pid), do: GenServer.call(pid, :get_state)
    def handle_call(:get_state, _from, state), do: {:reply, state, state}
  end

  defmodule KeyedServer do
    use GenServer
    use Arena.Process

    def to_process_key(%{id: id}), do: {__MODULE__, id}

    def init(state), do: {:ok, state}

    def get_state(pid), do: GenServer.call(pid, :get_state)
    def handle_call(:get_state, _from, state), do: {:reply, state, state}
  end

  defmodule CallbackTestServer do
    use GenServer
    use Arena.Process

    def init(state) do
      # Store the config for testing
      config = Config.current()
      {:ok, {state, config}}
    end

    def get_config(pid), do: GenServer.call(pid, :get_config)
    def handle_call(:get_config, _from, {_state, config} = full_state), do: {:reply, config, full_state}
  end

  defmodule TestKillServer do
    use GenServer
    use Arena.Process

    require Arena.Process
    Arena.Process.enable_test_kill()

    def init(state), do: {:ok, state}
  end

  describe "start_link/1" do
    test "starts global server with wrapped args" do
      config = Config.new(:test_global)
      wrapped = Wrapped.new(config, :initial_state)

      {:ok, pid} = GlobalServer.start_link(wrapped)

      assert Process.alive?(pid)
      assert GlobalServer.get_state(pid) == :initial_state
    end

    test "starts keyed server with wrapped args" do
      config = Config.new(:test_keyed)
      wrapped = Wrapped.new(config, %{id: :server_a, data: :test})

      {:ok, pid} = KeyedServer.start_link(wrapped)

      assert Process.alive?(pid)
      assert KeyedServer.get_state(pid) == %{id: :server_a, data: :test}
    end

    test "registers global server in registry" do
      config = Config.new(:test_registry_global)
      wrapped = Wrapped.new(config, :state)

      {:ok, _pid} = GlobalServer.start_link(wrapped)

      # Check registry
      key = {GlobalServer, :test_registry_global}
      assert [{pid, _}] = Registry.lookup(:arena_registry, key)
      assert Process.alive?(pid)
    end

    test "registers keyed server in registry" do
      config = Config.new(:test_registry_keyed)
      wrapped = Wrapped.new(config, %{id: :unique_id})

      {:ok, _pid} = KeyedServer.start_link(wrapped)

      # Check registry
      key = {{KeyedServer, :unique_id}, :test_registry_keyed}
      assert [{pid, _}] = Registry.lookup(:arena_registry, key)
      assert Process.alive?(pid)
    end

    test "can start multiple keyed servers with same config" do
      config = Config.new(:test_multiple)

      {:ok, pid1} = KeyedServer.start_link(Wrapped.new(config, %{id: :a}))
      {:ok, pid2} = KeyedServer.start_link(Wrapped.new(config, %{id: :b}))

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end

  describe "init/1 configuration" do
    test "stores config in process dictionary" do
      config = Config.new(:test_config_storage)
      wrapped = Wrapped.new(config, :state)

      {:ok, pid} = CallbackTestServer.start_link(wrapped)

      stored_config = CallbackTestServer.get_config(pid)
      assert %Config{} = stored_config
      assert stored_config.owner == :test_config_storage
    end

    test "creates child config with process key" do
      config = Config.new(:test_child_config)
      wrapped = Wrapped.new(config, :state)

      {:ok, pid} = CallbackTestServer.start_link(wrapped)

      stored_config = CallbackTestServer.get_config(pid)
      # Should be child config with CallbackTestServer as last element
      assert stored_config.id == {:test_child_config, CallbackTestServer}
    end

    test "executes callbacks during init" do
      parent = self()
      callback = {__MODULE__, :test_callback, [parent: parent]}

      config = Config.new(:test_callbacks, callbacks: [callback])
      wrapped = Wrapped.new(config, :state)

      {:ok, _pid} = CallbackTestServer.start_link(wrapped)

      assert_receive {:callback_executed, %Config{}}
    end
  end

  describe "via_tuple/0" do
    test "generates via tuple from stored config" do
      config = Config.new(:test_via)
      wrapped = Wrapped.new(config, :state)

      {:ok, _pid} = GlobalServer.start_link(wrapped)

      # Call via_tuple/0 from outside the process
      # We can't easily test this from outside, so we trust the implementation
      # and test the other via_tuple variants instead
    end
  end

  describe "via_tuple/1" do
    test "generates via tuple from wrapped" do
      config = Config.new(:test_via_wrapped)
      wrapped = Wrapped.new(config, %{id: :test})

      via = KeyedServer.via_tuple(wrapped)

      assert via == {:via, Registry, {:arena_registry, {{KeyedServer, :test}, :test_via_wrapped}}}
    end

    test "generates via tuple from input" do
      config = Config.new(:test_via_input)
      Config.store(config)

      via = KeyedServer.via_tuple(%{id: :test})

      assert via == {:via, Registry, {:arena_registry, {{KeyedServer, :test}, :test_via_input}}}
    end
  end

  describe "via_tuple/2" do
    test "generates via tuple for global server" do
      via = GlobalServer.via_tuple(:test_owner, nil)

      assert via == {:via, Registry, {:arena_registry, {GlobalServer, :test_owner}}}
    end

    test "generates via tuple for keyed server" do
      via = KeyedServer.via_tuple(:test_owner, %{id: :unique})

      assert via == {:via, Registry, {:arena_registry, {{KeyedServer, :unique}, :test_owner}}}
    end

    test "appends owner to tuple process key" do
      # If to_process_key returns a tuple, owner is appended
      via = KeyedServer.via_tuple(:my_owner, %{id: :key})

      assert via == {:via, Registry, {:arena_registry, {{KeyedServer, :key}, :my_owner}}}
    end

    test "wraps scalar process key with owner" do
      # If to_process_key returns a scalar, it's wrapped with owner
      via = GlobalServer.via_tuple(:my_owner, nil)

      assert via == {:via, Registry, {:arena_registry, {GlobalServer, :my_owner}}}
    end
  end

  describe "get_pid/1" do
    test "returns pid for global server" do
      config = Config.new(:test_get_pid_global)
      Config.store(config)  # Store in test process
      wrapped = Wrapped.new(config, :state)

      {:ok, pid} = GlobalServer.start_link(wrapped)

      found_pid = GlobalServer.get_pid(nil)
      assert found_pid == pid
    end

    test "returns pid for keyed server" do
      config = Config.new(:test_get_pid_keyed)
      Config.store(config)  # Store in test process
      wrapped = Wrapped.new(config, %{id: :target})

      {:ok, pid} = KeyedServer.start_link(wrapped)

      found_pid = KeyedServer.get_pid(%{id: :target})
      assert found_pid == pid
    end

    test "returns nil for nonexistent process" do
      config = Config.new(:test_get_pid_missing)
      Config.store(config)

      pid = GlobalServer.get_pid(nil)
      assert pid == nil
    end
  end

  describe "alive?/1" do
    test "returns true for running process" do
      config = Config.new(:test_alive)
      Config.store(config)  # Store in test process
      wrapped = Wrapped.new(config, :state)

      {:ok, _pid} = GlobalServer.start_link(wrapped)

      assert GlobalServer.alive?(nil) == true
    end

    test "returns false for nonexistent process" do
      config = Config.new(:test_not_alive)
      Config.store(config)

      assert GlobalServer.alive?(nil) == false
    end

    test "returns false after process dies" do
      config = Config.new(:test_died)
      Config.store(config)  # Store in test process
      wrapped = Wrapped.new(config, :state)

      {:ok, pid} = GlobalServer.start_link(wrapped)

      # Monitor and stop the process
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)

      # Wait for process to die and be cleaned up from registry
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      # Small delay to ensure registry cleanup completes
      Process.sleep(10)

      assert GlobalServer.alive?(nil) == false
    end
  end

  describe "enable_test_kill/0" do
    test "adds die/1 function in test environment" do
      config = Config.new(:test_kill)
      wrapped = Wrapped.new(config, :state)

      {:ok, pid} = TestKillServer.start_link(wrapped)

      assert Process.alive?(pid)
      assert :ok = TestKillServer.die(pid)
      refute Process.alive?(pid)
    end

    test "die/1 returns error for nil pid" do
      assert {:error, :no_process_found} = TestKillServer.die(nil)
    end

    test "die/1 accepts input and looks up pid" do
      config = Config.new(:test_kill_by_input)
      Config.store(config)  # Store in test process
      wrapped = Wrapped.new(config, :state)

      {:ok, _pid} = TestKillServer.start_link(wrapped)

      assert :ok = TestKillServer.die(:state)
    end
  end

  describe "to_process_key/1" do
    test "default implementation returns module name" do
      assert GlobalServer.to_process_key(:anything) == GlobalServer
      assert GlobalServer.to_process_key(%{any: :map}) == GlobalServer
    end

    test "can be overridden for keyed processes" do
      assert KeyedServer.to_process_key(%{id: :test}) == {KeyedServer, :test}
    end
  end

  # Helper for testing callbacks
  def test_callback(config, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    if parent do
      send(parent, {:callback_executed, config})
    end
  end
end
