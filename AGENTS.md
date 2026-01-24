# Arena: Agent Onboarding Guide

**For agents/developers familiar with Elixir and ExUnit but new to Arena**

## The Core Problem

When running async ExUnit tests with `Ecto.Adapters.SQL.Sandbox`, database transactions provide isolation between tests. However, **spawned processes don't inherit the test's database connection**.

```elixir
# ❌ This breaks in async tests
test "my test" do
  # Test has DB transaction
  user = Repo.insert!(%User{name: "Alice"})

  # GenServer spawns - LOSES DB access
  {:ok, pid} = MyServer.start_link(user.id)

  # This fails - MyServer can't see the user in its transaction
  assert MyServer.get_user_name(pid) == "Alice"
end
```

**Traditional solutions:**
- Run tests synchronously (`async: false`) - Slow
- Manually call `Ecto.Adapters.SQL.Sandbox.allow/3` for every spawned process - Brittle
- Arena - Automatic isolation infrastructure per test

## The Solution: Three Pieces

### 1. Config (Blueprint)

A struct containing test infrastructure details that gets passed down the process tree:

```elixir
%Arena.Config{
  owner: :my_test,           # Root identifier (test name)
  id: {:my_test, Server},    # Hierarchical process tracking
  context: %{                # Infrastructure map
    pubsub_name: MyTest.PubSub,
    custom_data: :value
  },
  callbacks: [               # Lazy setup functions
    {Ecto.Adapters.SQL.Sandbox, :allow, [repo: Repo, ancestor_pid: test_pid]}
  ]
}
```

### 2. Wrapped (Envelope)

A container that carries both the Config and the actual process arguments:

```elixir
%Arena.Wrapped{
  config: %Arena.Config{...},  # Infrastructure
  input: :actual_args           # What your process actually needs
}
```

### 3. Process (Macro)

GenServers `use Arena.Process` to automatically:
1. Unwrap the `Wrapped` struct
2. Store config in process dictionary
3. Execute callbacks (grants DB access)
4. Call your `init/1` with clean args
5. Register via Registry for lookup

## Mental Model

Think of Arena as **dependency injection for test infrastructure**:

```elixir
# Test setup creates the "world" for this test
config = Arena.setup(context)
|> Arena.Integrations.Ecto.setup(repo: Repo)
|> Arena.Integrations.PubSub.setup()

# Every process gets wrapped with that world
{MyServer, Arena.wrap(config, :args)}
  ↓
MyServer automatically:
  - Stores config
  - Gets DB access (via callback)
  - Gets PubSub name (from context)
  - Registers in Registry
  - Calls your init(:args)
```

## Key Architecture Patterns

### Pattern 1: Config Flows Down, Never Up

```elixir
# Test creates root config
config = Arena.setup(:my_test)
# id: {:my_test}

# Supervisor spawns, gets child config
{MySupervisor, Arena.wrap(config, opts)}
# Supervisor's id: {:my_test, MySupervisor}

# Worker spawns from supervisor, gets grandchild config
{MyWorker, Arena.wrap(Config.current(), args)}
# Worker's id: {:my_test, MySupervisor, MyWorker}
```

### Pattern 2: Callbacks Execute at Process Init

Callbacks are **lazy** - they run when a process starts, not when added to config:

```elixir
# At test setup
config = Arena.setup(context)
|> Arena.Integrations.Ecto.setup(repo: Repo)
# This ADDS a callback, doesn't execute it yet

# When GenServer starts
{MyServer, Arena.wrap(config, args)}
# NOW the callback executes in MyServer's process
# MyServer gets authorized for DB access
```

### Pattern 3: Two APIs - Explicit and Implicit

```elixir
# Explicit (pass config around)
config = Arena.Config.new(:test)
value = Arena.Config.get(config, :key)

# Implicit (uses process dictionary)
Arena.Config.store(config)
value = Arena.Config.get(:key)        # No config arg
config = Arena.Config.current()       # From process dict
```

## Common Scenarios

### Global Process (One per test)

```elixir
defmodule MyGlobalServer do
  use GenServer
  use Arena.Process  # Default: one instance per owner

  def init(state), do: {:ok, state}
end

# In test
{MyGlobalServer, Arena.wrap(config, :state)}
```

### Keyed Process (Multiple per test)

```elixir
defmodule MyUserServer do
  use GenServer
  use Arena.Process

  # Override to make unique by user_id
  def to_process_key(%{user_id: id}), do: {__MODULE__, id}

  def init(args), do: {:ok, args}
end

# In test - can spawn multiple
{MyUserServer, Arena.wrap(config, %{user_id: 1})}
{MyUserServer, Arena.wrap(config, %{user_id: 2})}
```

### Supervisor

```elixir
defmodule MySupervisor do
  use Supervisor
  use Arena.Supervisor  # Simpler than Process

  def init(_opts) do
    config = Arena.Config.current()  # Get from process dict

    children = [
      # You must explicitly wrap children
      {Worker, Arena.wrap(config, :worker_args)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### Task

```elixir
# Spawned tasks inherit config automatically
task = Arena.Task.async(fn ->
  # This task has DB access
  Repo.get(User, 1)
end)

# Parallel processing with DB access
results = Arena.Task.async_stream(user_ids, fn id ->
  Repo.get(User, id)
end) |> Enum.to_list()
```

## Registry Keys

Processes register with composite keys: `{process_key, owner}`

```elixir
# Global process
{MyServer, :my_test}

# Keyed process
{{MyServer, :user_123}, :my_test}

# Lookup
{:via, Registry, {:arena_registry, {MyServer, :my_test}}}
```

## What Gets Isolated Per Test

Each test gets its own:
- **PubSub server** - Messages don't leak between tests
- **Registry namespace** - Process names scoped by test
- **Database transaction** - Via Sandbox callbacks
- **Config hierarchy** - Process tree tracking

## What You Need to Remember

1. **Wrap everything**: `{Server, Arena.wrap(config, args)}` not `{Server, args}`
2. **GenServers need the macro**: `use Arena.Process` to unwrap automatically
3. **Supervisors need the macro too**: `use Arena.Supervisor` and wrap children manually
4. **Tasks use the wrapper**: `Arena.Task.async(fn -> ... end)` not `Task.async`
5. **Callbacks are lazy**: Added at setup, executed at process init
6. **Config flows down**: Get current config with `Config.current()`, wrap for children

## Anti-Patterns to Avoid

### ❌ Forgetting to wrap
```elixir
# This won't work - no config
{MyServer, :args}
```

### ❌ Not using the macro
```elixir
defmodule MyServer do
  use GenServer
  # Missing: use Arena.Process
end
```

### ❌ Wrapping children in Supervisor with parent's input
```elixir
# Wrong - wrapping the supervisor's input, not the config
def init(input) do
  children = [{Worker, Arena.wrap(input, :args)}]  # ❌
end

# Right - get config, wrap children with config
def init(_input) do
  config = Arena.Config.current()
  children = [{Worker, Arena.wrap(config, :args)}]  # ✓
end
```

### ❌ Using Task.async instead of Arena.Task.async
```elixir
# This task won't have DB access
Task.async(fn -> Repo.get(User, 1) end)  # ❌

# This will
Arena.Task.async(fn -> Repo.get(User, 1) end)  # ✓
```

## Quick Reference

```elixir
# Setup
config = Arena.setup(context)
|> Arena.Integrations.Ecto.setup(repo: Repo)
|> Arena.Integrations.PubSub.setup()

# Wrap
wrapped = Arena.wrap(config, args)

# GenServer
use Arena.Process
def to_process_key(args), do: {__MODULE__, args.id}  # For keyed

# Supervisor
use Arena.Supervisor
config = Arena.Config.current()

# Task
Arena.Task.async(fn -> ... end)
Arena.Task.async_stream(enum, fn x -> ... end)

# Config
Arena.Config.get(config, :key)
Arena.Config.put(config, :key, :value)
Arena.Config.current()
```

## When to Use Arena

**Use Arena when:**
- Tests spawn GenServers, Supervisors, or Tasks
- You need async tests for speed
- Processes need DB access or PubSub
- You want isolated test infrastructure

**Don't use Arena when:**
- Tests are purely functional (no processes)
- Sync tests are acceptable
- No spawned processes need shared resources

## Further Reading

- **README.md** - Comprehensive guide with all features
- **Module docs** - Inline documentation for each module
- **Tests** - `test/arena/*_test.exs` for usage examples
