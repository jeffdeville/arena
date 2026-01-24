defmodule Arena.SupervisorTest do
  use ExUnit.Case, async: true

  alias Arena.Config
  alias Arena.Wrapped

  # Test worker for supervisor
  defmodule TestWorker do
    use GenServer
    use Arena.Process

    # Make it a keyed process based on state
    def to_process_key(state), do: {__MODULE__, state}

    def init(state) do
      # Store config for testing
      config = Config.current()
      {:ok, {state, config}}
    end

    def get_state(pid), do: GenServer.call(pid, :get_state)
    def get_config(pid), do: GenServer.call(pid, :get_config)

    def handle_call(:get_state, _from, {state, _config} = full_state) do
      {:reply, state, full_state}
    end

    def handle_call(:get_config, _from, {_state, config} = full_state) do
      {:reply, config, full_state}
    end
  end

  # Test supervisor
  defmodule TestSupervisor do
    use Supervisor
    use Arena.Supervisor

    def init(workers) do
      config = Config.current()

      children =
        Enum.with_index(workers)
        |> Enum.map(fn {worker_state, index} ->
          # Use unique IDs for each worker
          Supervisor.child_spec(
            {TestWorker, Wrapped.new(config, worker_state)},
            id: {TestWorker, index}
          )
        end)

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  # Test supervisor with callbacks
  defmodule CallbackSupervisor do
    use Supervisor
    use Arena.Supervisor

    def init(opts) do
      # Config should be available and have callbacks executed
      config = Config.current()

      # Send to parent if provided
      if is_map(opts) and Map.has_key?(opts, :parent) do
        send(opts.parent, {:supervisor_init, config})
      end

      Supervisor.init([], strategy: :one_for_one)
    end
  end

  describe "start_link/1" do
    test "starts supervisor with wrapped args" do
      config = Config.new(:test_supervisor)
      wrapped = Wrapped.new(config, [:worker1, :worker2])

      {:ok, pid} = TestSupervisor.start_link(wrapped)

      assert Process.alive?(pid)
      assert Supervisor.which_children(pid) |> length() == 2
    end

    test "supervisor can start workers that access config" do
      config = Config.new(:test_worker_config)
      wrapped = Wrapped.new(config, [:state_a])

      {:ok, sup_pid} = TestSupervisor.start_link(wrapped)

      # Get the worker
      [{_id, worker_pid, _type, _modules}] = Supervisor.which_children(sup_pid)

      # Worker should have the config
      worker_config = TestWorker.get_config(worker_pid)
      assert worker_config.owner == :test_worker_config
    end
  end

  describe "init/1 configuration" do
    test "stores config in supervisor process dictionary" do
      parent = self()
      callback = {__MODULE__, :test_callback, [parent: parent]}

      config = Config.new(:test_sup_config, callbacks: [callback])
      wrapped = Wrapped.new(config, %{parent: parent})

      {:ok, _pid} = CallbackSupervisor.start_link(wrapped)

      # Should receive message from init
      assert_receive {:supervisor_init, stored_config}
      assert stored_config.owner == :test_sup_config
    end

    test "creates child config with supervisor module name" do
      parent = self()
      callback = {__MODULE__, :test_callback, [parent: parent]}

      config = Config.new(:test_sup_child, callbacks: [callback])
      wrapped = Wrapped.new(config, %{parent: parent})

      {:ok, _pid} = CallbackSupervisor.start_link(wrapped)

      assert_receive {:supervisor_init, stored_config}
      # Should be child config with CallbackSupervisor as last element
      assert stored_config.id == {:test_sup_child, CallbackSupervisor}
    end

    test "executes callbacks during init" do
      parent = self()
      callback = {__MODULE__, :test_callback, [parent: parent]}

      config = Config.new(:test_sup_callbacks, callbacks: [callback])
      wrapped = Wrapped.new(config, %{parent: parent})

      {:ok, _pid} = CallbackSupervisor.start_link(wrapped)

      # Should receive callback execution
      assert_receive {:callback_executed, %Config{}}
    end
  end

  describe "child config propagation" do
    test "workers get child config from supervisor" do
      config = Config.new(:test_propagation)
      wrapped = Wrapped.new(config, [:worker_state])

      {:ok, sup_pid} = TestSupervisor.start_link(wrapped)

      # Get the worker
      [{_id, worker_pid, _type, _modules}] = Supervisor.which_children(sup_pid)

      # Worker should have config with supervisor in hierarchy
      worker_config = TestWorker.get_config(worker_pid)

      # Worker's config id should have TestSupervisor -> {TestWorker, :worker_state} hierarchy
      # Root -> Supervisor -> Worker (with process key)
      assert tuple_size(worker_config.id) == 3
      assert elem(worker_config.id, 0) == :test_propagation
      assert elem(worker_config.id, 1) == TestSupervisor
      # The process key is {TestWorker, :worker_state} because it's a keyed process
      assert elem(worker_config.id, 2) == {TestWorker, :worker_state}
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
