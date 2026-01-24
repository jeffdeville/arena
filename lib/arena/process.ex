defmodule Arena.Process do
  @moduledoc """
  Macro for GenServers to integrate with Arena's test isolation system.

  `Arena.Process` (formerly known as Client in Belay.Wiring) provides a macro that
  GenServers can `use` to automatically handle Arena configuration, process registration,
  and infrastructure setup.

  ## What It Does

  When you `use Arena.Process`, the macro injects:

  1. **start_link/1** - Accepts `Arena.Wrapped`, registers via Registry, calls init
  2. **init/1 wrapper** - Intercepts init to configure Arena, then calls your init
  3. **via_tuple helpers** - Generate Registry names for process lookup
  4. **to_process_key/1** - Callback to define unique process identification
  5. **get_pid/1, alive?/1** - Helpers to find and check processes
  6. **enable_test_kill/0** - Optional macro for test cleanup (test env only)

  ## Usage

      defmodule MyServer do
        use GenServer
        use Arena.Process

        # Your init receives the unwrapped input
        def init(initial_state) do
          {:ok, initial_state}
        end

        # Override for non-global processes
        def to_process_key(%{user_id: user_id}), do: {__MODULE__, user_id}
      end

      # In tests
      config = Arena.setup(:my_test)
      {:ok, pid} = MyServer.start_link(Arena.wrap(config, %{user_id: 123}))

  ## Process Keys and Registration

  Processes are registered in `:arena_registry` using a key derived from:
  - The module name (or custom key from `to_process_key/1`)
  - The owner (from config)

  For global processes (one per test), the default `to_process_key/1` returns `__MODULE__`.
  For keyed processes (multiple per test), override it to return a unique tuple.

  ## Examples

      # Global process (one instance per test)
      defmodule MyGlobalServer do
        use GenServer
        use Arena.Process

        def init(_), do: {:ok, %{}}
      end

      # Keyed process (multiple instances per test)
      defmodule MyKeyedServer do
        use GenServer
        use Arena.Process

        def to_process_key(%{id: id}), do: {__MODULE__, id}
        def init(args), do: {:ok, args}
      end

      # With test cleanup
      defmodule MyTestServer do
        use GenServer
        use Arena.Process

        enable_test_kill()

        def init(_), do: {:ok, %{}}
      end

      # Usage
      config = Arena.setup(:my_test)
      {:ok, pid1} = MyGlobalServer.start_link(Arena.wrap(config, nil))
      {:ok, pid2} = MyKeyedServer.start_link(Arena.wrap(config, %{id: :a}))
      {:ok, pid3} = MyKeyedServer.start_link(Arena.wrap(config, %{id: :b}))
  """

  @doc """
  Callback to determine the unique process key from input arguments.

  Override this in your GenServer to support multiple instances per test.
  The return value is used as part of the Registry key.

  ## Examples

      # Global process (default)
      def to_process_key(_input), do: __MODULE__

      # Keyed by user_id
      def to_process_key(%{user_id: user_id}), do: {__MODULE__, user_id}

      # Keyed by symbol
      def to_process_key(symbol) when is_atom(symbol), do: {__MODULE__, symbol}
  """
  @callback to_process_key(input :: any()) :: module() | tuple()

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Arena.Process

      alias Arena.Config
      alias Arena.Wrapped

      @doc """
      Starts the GenServer with Arena configuration.

      Accepts an `Arena.Wrapped` struct containing both the config and input args.
      Registers the process via Registry using a via tuple.

      ## Examples

          config = Arena.Config.new(:my_test)
          wrapped = Arena.Wrapped.new(config, :initial_state)
          {:ok, pid} = MyServer.start_link(wrapped)
      """
      @spec start_link(Wrapped.t()) :: GenServer.on_start()
      def start_link(%Wrapped{} = wrapped) do
        GenServer.start_link(__MODULE__, wrapped, name: via_tuple(wrapped))
      end

      @doc """
      Determines the unique process key from input arguments.

      Default implementation returns `__MODULE__`, making this a global process
      (one instance per test). Override to support multiple instances.

      ## Examples

          # Override for keyed processes
          def to_process_key(%{user_id: user_id}), do: {__MODULE__, user_id}
      """
      def to_process_key(_input), do: __MODULE__

      defoverridable to_process_key: 1

      @doc """
      Wraps the user's init/1 to configure Arena before calling it.

      This is injected by the macro and intercepts the init call to:
      1. Extract the config from Wrapped
      2. Create a child config with this process's key
      3. Store config in process dictionary
      4. Execute callbacks (Ecto auth, PubSub setup, etc.)
      5. Call the user's init/1 with the unwrapped input

      The user's init/1 should be defined to accept the unwrapped input.
      """
      def init(%Wrapped{} = wrapped) do
        configure_arena(wrapped)
        init(wrapped.input)
      end

      @doc """
      Generates a via tuple for Registry-based process naming.

      Via tuples are used by GenServer to register and lookup processes.
      The key format is: `{process_key, owner}` where:
      - `process_key` is from `to_process_key/1`
      - `owner` is from the config

      ## Examples

          # From stored config (after init)
          via_tuple()
          #=> {:via, Registry, {:arena_registry, {MyServer, :my_test}}}

          # From input (before init)
          via_tuple(%{user_id: 123})
          #=> {:via, Registry, {:arena_registry, {{MyServer, 123}, :my_test}}}

          # From explicit owner and input
          via_tuple(:my_test, %{user_id: 123})
          #=> {:via, Registry, {:arena_registry, {{MyServer, 123}, :my_test}}}
      """
      @spec via_tuple() :: {:via, atom(), term()}
      def via_tuple do
        via_tuple(Config.get(:owner), nil)
      end

      @spec via_tuple(Wrapped.t() | any()) :: {:via, atom(), term()}
      def via_tuple(%Wrapped{config: config, input: input}) do
        via_tuple(config.owner, input)
      end

      def via_tuple(input) do
        via_tuple(Config.get(:owner), input)
      end

      @spec via_tuple(atom(), any()) :: {:via, atom(), term()}
      def via_tuple(owner, input) do
        key =
          case __MODULE__.to_process_key(input) do
            process_key when is_tuple(process_key) ->
              {process_key, owner}

            process_key ->
              {process_key, owner}
          end

        {:via, Registry, {:arena_registry, key}}
      end

      @doc """
      Gets the PID of a process instance by its input args.

      Looks up the process in the Registry using the via tuple.

      ## Examples

          # Global process
          pid = MyGlobalServer.get_pid(nil)

          # Keyed process
          pid = MyKeyedServer.get_pid(%{user_id: 123})

          # Returns nil if not found
          MyServer.get_pid(:nonexistent)
          #=> nil
      """
      def get_pid(state) do
        {:via, Registry, {registry, key}} = via_tuple(state)

        case Registry.lookup(registry, key) do
          [{pid, _}] -> pid
          _ -> nil
        end
      end

      @doc """
      Checks if a process instance is alive.

      ## Examples

          MyServer.alive?(%{user_id: 123})
          #=> true

          MyServer.alive?(:nonexistent)
          #=> false
      """
      def alive?(state) do
        get_pid(state) != nil
      end

      @doc false
      defp configure_arena(%Wrapped{config: parent_config, input: input}) do
        process_key = to_process_key(input)

        parent_config
        |> Config.child(process_key)
        |> Config.store()
        |> Config.execute_callbacks()
      end
    end
  end

  @doc """
  Macro to enable test cleanup functionality.

  Only active in test environment. Adds a `die/1` function and `:die` message handler
  that allows tests to cleanly shut down processes.

  ## Usage

      defmodule MyServer do
        use GenServer
        use Arena.Process

        enable_test_kill()

        def init(_), do: {:ok, %{}}
      end

      # In tests
      pid = MyServer.get_pid(args)
      MyServer.die(pid)  # Cleanly stops the process
  """
  defmacro enable_test_kill do
    case Mix.env() do
      :test ->
        quote location: :keep do
          @doc """
          Stops a process cleanly (test environment only).

          Sends a `:die` message and waits for the process to terminate.

          ## Examples

              pid = MyServer.get_pid(args)
              MyServer.die(pid)
              #=> :ok

              MyServer.die(nil)
              #=> {:error, :no_process_found}
          """
          def die(nil), do: {:error, :no_process_found}

          def die(pid) when is_pid(pid) do
            Process.monitor(pid)
            send(pid, :die)

            receive do
              {:DOWN, _, :process, ^pid, _reason} -> :ok
            after
              1_000 -> {:error, :process_did_not_die}
            end
          end

          def die(input), do: get_pid(input) |> die()

          @doc false
          def handle_info(:die, state), do: {:stop, :normal, state}
        end

      _ ->
        nil
    end
  end
end
