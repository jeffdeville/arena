# Arena

**Process isolation for async Elixir testing**

Arena (Latin for "sand", from Roman amphitheater floors) provides a sandbox for testing process-heavy Elixir applications asynchronously. It solves the fundamental problem of maintaining database transaction isolation when your code spawns GenServers, supervisors, or tasks.

## The Problem

In Elixir, async tests typically use database transactions for isolation via `Ecto.Adapters.SQL.Sandbox`. However, when your application spawns new processes (GenServers, supervisors, tasks), these processes don't share the test's database transaction.

Traditional solutions:
1. **Run tests synchronously** - Slow, defeats the purpose of async testing
2. **Accept global state** - Brittle, tests interfere with each other
3. **Arena's approach** - Each test gets its own isolated infrastructure

## The Solution

Arena provides each test with its own isolated infrastructure:
- Separate PubSub server per test
- Unique Registry names for process lookup
- Database connection sharing via `Ecto.Adapters.SQL.Sandbox`
- Hierarchical process tracking for debugging

## Installation

Add `arena` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:arena, path: "../arena"}  # When using as a local dependency
  ]
end
```

## Setup

### 1. Add Registry to Your Application

In your `application.ex`:

```elixir
def start(_type, _args) do
  children = [
    {Registry, keys: :unique, name: :arena_registry},
    # ... your other children
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### 2. Set Up Your Test Case

Create or update your `DataCase`:

```elixir
defmodule MyApp.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MyApp.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MyApp.DataCase
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
    end

    # Set up Arena
    config = Arena.setup(tags)
    |> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
    |> Arena.Integrations.PubSub.setup()

    {:ok, arena: config}
  end
end
```

### 3. Update Your GenServers

```elixir
defmodule MyApp.MyServer do
  use GenServer
  use Arena.Process  # Add this line

  def init(state) do
    {:ok, state}
  end

  # ... rest of your GenServer
end
```

### 4. Write Async Tests

```elixir
defmodule MyApp.MyServerTest do
  use MyApp.DataCase, async: true  # Note: async: true

  test "server can access database", %{arena: config} do
    # Start your server with Arena
    {:ok, pid} = start_supervised!({MyApp.MyServer, Arena.wrap(config, :initial_state)})

    # The server can now access the database in the same transaction
    # as your test
    assert MyApp.MyServer.do_something(pid) == :expected_result
  end
end
```

## Core Concepts

### Config

The blueprint containing infrastructure details:
- `owner` - Root identifier (test name)
- `id` - Hierarchical tuple tracking process tree
- `context` - Map of infrastructure (pubsub_name, etc.)
- `callbacks` - Setup functions executed when processes start

### Wrapped

An envelope carrying both config and process arguments:

```elixir
config = Arena.Config.new(:my_test)
wrapped = Arena.Wrapped.new(config, :my_args)
# or
wrapped = Arena.wrap(config, :my_args)
```

### Process

A macro that GenServers use to integrate with Arena:

```elixir
defmodule MyServer do
  use GenServer
  use Arena.Process

  def init(state), do: {:ok, state}
end
```

## Usage Patterns

### Global Processes

One instance per test:

```elixir
defmodule MyApp.GlobalServer do
  use GenServer
  use Arena.Process

  def init(state), do: {:ok, state}
end

# In tests
config = Arena.setup(:my_test)
{:ok, pid} = MyApp.GlobalServer.start_link(Arena.wrap(config, :state))
```

### Keyed Processes

Multiple instances per test:

```elixir
defmodule MyApp.UserServer do
  use GenServer
  use Arena.Process

  # Override to make instances unique by user_id
  def to_process_key(%{user_id: user_id}), do: {__MODULE__, user_id}

  def init(args), do: {:ok, args}
end

# In tests
config = Arena.setup(:my_test)
{:ok, pid1} = MyApp.UserServer.start_link(Arena.wrap(config, %{user_id: 1}))
{:ok, pid2} = MyApp.UserServer.start_link(Arena.wrap(config, %{user_id: 2}))
```

### Supervisors

```elixir
defmodule MyApp.WorkerSupervisor do
  use Supervisor
  use Arena.Supervisor

  def init(_opts) do
    config = Arena.Config.current()

    children = [
      {MyApp.Worker, Arena.wrap(config, :worker_args)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# In tests
config = Arena.setup(:my_test)
{:ok, sup} = MyApp.WorkerSupervisor.start_link(Arena.wrap(config, nil))
```

### Tasks

```elixir
# Async task with database access
task = Arena.Task.async(fn ->
  MyApp.Repo.get(User, 1)
end)

user = Task.await(task)

# Parallel processing
results = Arena.Task.async_stream([1, 2, 3], fn id ->
  MyApp.Repo.get(User, id)
end, max_concurrency: 10)
|> Enum.to_list()
```

## Integrations

### Ecto

Enables database access for spawned processes:

```elixir
config = Arena.setup(context)
|> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
```

Multiple repos:

```elixir
config = Arena.setup(context)
|> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
|> Arena.Integrations.Ecto.setup(repo: MyApp.Analytics.Repo)
```

### Phoenix.PubSub

Creates isolated PubSub server per test:

```elixir
config = Arena.setup(context)
|> Arena.Integrations.PubSub.setup()

# Access in GenServers
pubsub_name = Arena.Config.get(:pubsub_name)
Phoenix.PubSub.subscribe(pubsub_name, "my_topic")
```

Custom PubSub name:

```elixir
config = Arena.setup(context)
|> Arena.Integrations.PubSub.setup(name: MyCustomPubSub)
```

## Advanced Features

### Process Hierarchy Tracking

Arena tracks process spawning hierarchies:

```elixir
config = Arena.setup(:my_test)
# id: {:my_test}

# Spawn supervisor
# id: {:my_test, MySupervisor}

# Spawn worker from supervisor
# id: {:my_test, MySupervisor, {MyWorker, :key}}
```

Useful for debugging:

```elixir
config = Arena.Config.current()
IO.inspect(Arena.Config.to_string(config))
# => "my_test/MySupervisor/MyWorker/:key"
```

### Custom Callbacks

Add custom setup logic:

```elixir
defmodule MySetup do
  def configure(config, opts) do
    # Custom setup logic
    :ok
  end
end

config = Arena.setup(:my_test)
|> Arena.Config.add_callback({MySetup, :configure, [key: :value]})
```

### Context Storage

Store arbitrary data in config:

```elixir
config = Arena.Config.put(config, :custom_key, :custom_value)

# Access later
value = Arena.Config.get(config, :custom_key)
```

## Testing Arena-Enabled Code

### With start_supervised!

```elixir
test "my test", %{arena: config} do
  {:ok, pid} = start_supervised!({MyServer, Arena.wrap(config, :state)})
  assert MyServer.do_something(pid) == :result
end
```

### Finding Processes

```elixir
# For global processes
pid = MyGlobalServer.get_pid(nil)

# For keyed processes
pid = MyKeyedServer.get_pid(%{id: :key})

# Check if alive
MyServer.alive?(%{id: :key})  #=> true/false
```

### Test Cleanup

Enable test cleanup (test env only):

```elixir
defmodule MyServer do
  use GenServer
  use Arena.Process

  require Arena.Process
  Arena.Process.enable_test_kill()

  def init(state), do: {:ok, state}
end

# In tests
MyServer.die(pid)  # Cleanly stops the process
```

## Design Philosophy

### Explicit Over Implicit

Arena prefers explicit wrapping over magic:

```elixir
# Explicit - you see Arena is involved
{MyServer, Arena.wrap(config, args)}

# Not: implicit wrapping that hides Arena
{MyServer, args}  # ✗ Magic wrapping
```

### Minimal Process Dictionary Use

While Arena uses process dictionary for ergonomics, all functions accept explicit config:

```elixir
# Explicit
config = Arena.Config.new(:my_test)
value = Arena.Config.get(config, :key)

# Implicit (uses process dictionary)
Arena.Config.store(config)
value = Arena.Config.get(:key)
```

### No Global State

Each test gets completely isolated infrastructure. No shared global state between tests.

## Troubleshooting

### "Process not found" errors

Ensure you're storing the config before calling `get_pid`:

```elixir
config = Arena.setup(:my_test)
Arena.Config.store(config)  # Store in test process

pid = MyServer.get_pid(args)
```

### "Already started" errors

Make sure each process has a unique key:

```elixir
# For multiple instances of the same module
def to_process_key(args), do: {__MODULE__, args.id}
```

### Database connection errors

Ensure Ecto integration is set up:

```elixir
config = Arena.setup(context)
|> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
```

### PubSub not found

Ensure PubSub integration is set up:

```elixir
config = Arena.setup(context)
|> Arena.Integrations.PubSub.setup()
```

## Comparison to Alternatives

### vs Manual Database Modes

```elixir
# Manual approach
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  # Every spawned process needs manual allow
  spawn(fn ->
    Ecto.Adapters.SQL.Sandbox.allow(Repo, parent_pid, self())
    # Your code
  end)
end

# Arena approach
setup context do
  config = Arena.setup(context)
  |> Arena.Integrations.Ecto.setup(repo: Repo)
  {:ok, arena: config}
end

# Processes automatically authorized
{MyServer, Arena.wrap(config, args)}
```

### vs Synchronous Tests

```elixir
# Synchronous (slow)
use MyApp.DataCase, async: false

# Arena (fast)
use MyApp.DataCase, async: true
```

## Origin

Arena is a clean reimplementation of the proven Belay.Wiring system, with:
- Improved naming (Config, Wrapped, Process vs Schematic, Wireable, Client)
- Better ergonomics and composability
- Comprehensive documentation
- Standalone library design

**Name Origin**: "Arena" means "sand" in Latin, from the sand-covered floors of Roman amphitheaters, connecting to the sandbox metaphor while being memorable and professional.

## License

MIT

## Contributing

Contributions welcome! Please open an issue or PR.

## Credits

Based on the Belay.Wiring system, reimagined for broader use.
