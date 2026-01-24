defmodule Arena do
  @moduledoc """
  Process isolation for async Elixir testing.

  Arena (Latin for "sand", from Roman amphitheater floors) provides a sandbox for testing
  process-heavy Elixir applications asynchronously. It solves the fundamental problem of
  maintaining database transaction isolation when your code spawns GenServers, supervisors,
  or tasks.

  ## The Problem

  In Elixir, async tests typically use database transactions for isolation via
  `Ecto.Adapters.SQL.Sandbox`. However, when your application spawns new processes
  (GenServers, supervisors, tasks), these processes don't share the test's database
  transaction.

  Traditional solutions:
  1. **Run tests synchronously** - Slow, defeats async testing
  2. **Accept global state** - Brittle, tests interfere with each other
  3. **Arena's approach** - Each test gets isolated infrastructure

  ## The Solution

  Arena provides each test with its own isolated infrastructure:
  - Separate PubSub server
  - Unique Registry names for process lookup
  - Database connection sharing via Ecto.Adapters.SQL.Sandbox
  - Hierarchical process tracking

  ## Quick Start

      # 1. Add to your application supervision tree
      children = [
        {Registry, keys: :unique, name: :arena_registry},
        # ... other children
      ]

      # 2. Set up your test case
      defmodule MyApp.DataCase do
        use ExUnit.CaseTemplate

        setup context do
          config = Arena.setup(context)
          |> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
          |> Arena.Integrations.PubSub.setup()

          {:ok, arena: config}
        end
      end

      # 3. Update your GenServers
      defmodule MyApp.Server do
        use GenServer
        use Arena.Process

        def init(state), do: {:ok, state}
      end

      # 4. Write async tests
      defmodule MyApp.ServerTest do
        use MyApp.DataCase, async: true

        test "server works", %{arena: config} do
          {:ok, pid} = start_supervised!({MyApp.Server, Arena.wrap(config, :state)})
          assert Process.alive?(pid)
        end
      end

  ## Core Concepts

  Arena has three main pieces:

  1. **Config** - Blueprint containing infrastructure details
  2. **Wrapped** - Envelope carrying config + process arguments
  3. **Process** - Macro that GenServers use to integrate

  ## Workflow

      # Test setup
      config = Arena.setup(context)
      #=> Creates config with owner, id, context, callbacks

      # Add integrations
      config = Arena.Integrations.Ecto.setup(config, repo: MyApp.Repo)
      #=> Adds callback for DB authorization

      # Wrap arguments
      wrapped = Arena.wrap(config, :my_args)
      #=> Creates envelope with config + args

      # Start process
      {:ok, pid} = MyServer.start_link(wrapped)
      #=> Process registered, config stored, callbacks executed, init called

  ## Process Hierarchy

  Arena tracks process hierarchies using tuple-based IDs:

      config = Arena.setup(:my_test)
      #=> %Config{id: {:my_test}, ...}

      # Spawned GenServer
      #=> %Config{id: {:my_test, MyServer}, ...}

      # Spawned from GenServer
      #=> %Config{id: {:my_test, MyServer, :worker_1}, ...}

  ## Registry Keys

  Processes are registered in `:arena_registry` with keys like:
  - Global: `{MyServer, :my_test}`
  - Keyed: `{{MyServer, :user_123}, :my_test}`

  ## Examples

      # Global process (one per test)
      defmodule GlobalServer do
        use GenServer
        use Arena.Process

        def init(_), do: {:ok, %{}}
      end

      config = Arena.setup(:test_1)
      {:ok, pid} = GlobalServer.start_link(Arena.wrap(config, nil))

      # Keyed process (multiple per test)
      defmodule KeyedServer do
        use GenServer
        use Arena.Process

        def to_process_key(%{id: id}), do: {__MODULE__, id}
        def init(args), do: {:ok, args}
      end

      {:ok, pid1} = KeyedServer.start_link(Arena.wrap(config, %{id: :a}))
      {:ok, pid2} = KeyedServer.start_link(Arena.wrap(config, %{id: :b}))
  """

  alias Arena.Config
  alias Arena.Wrapped

  @doc """
  Creates an Arena config from a test context or owner atom.

  This is the entry point for Arena. Call it in your test setup to create
  the configuration blueprint for your test's infrastructure.

  ## Examples

      # From ExUnit test context
      setup context do
        config = Arena.setup(context)
        {:ok, arena: config}
      end

      # From atom
      config = Arena.setup(:my_test)

      # With options
      config = Arena.setup(:my_test, context: %{custom_key: :value})
  """
  @spec setup(atom() | map(), keyword()) :: Config.t()
  defdelegate setup(owner_or_context, opts \\ []), to: Config, as: :new

  @doc """
  Wraps config and input into an Arena.Wrapped envelope.

  Use this to prepare arguments for starting Arena-enabled processes.

  ## Examples

      config = Arena.setup(:my_test)
      wrapped = Arena.wrap(config, :my_args)

      {:ok, pid} = MyServer.start_link(wrapped)
  """
  @spec wrap(Config.t(), any()) :: Wrapped.t()
  defdelegate wrap(config, input \\ nil), to: Wrapped, as: :new
end
