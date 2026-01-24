defmodule Arena.Config do
  @moduledoc """
  Configuration blueprint for Arena-managed test infrastructure.

  `Arena.Config` (formerly known as Schematic in Belay.Wiring) is the central blueprint
  that maps out the connections and infrastructure needed for isolated async testing.

  ## Core Concepts

  Arena solves the problem of testing process-heavy Elixir applications asynchronously.
  When tests spawn GenServers, supervisors, or tasks, these processes don't share the
  test's database transaction by default. Arena provides each test with its own isolated
  infrastructure.

  A Config contains:

  - `owner` - Root identifier for this test's infrastructure (typically the test name as an atom)
  - `id` - Hierarchical tuple tracking the process tree position:
    - Root: `{owner}`
    - First child: `{owner, child_key}`
    - Grandchild: `{owner, child_key, grandchild_key}`
  - `context` - Map of infrastructure details (pubsub_name, queue_name, etc.)
  - `callbacks` - List of lazy setup functions executed when child processes start

  ## Examples

      # Create a config for a test
      config = Arena.Config.new(:my_test)
      #=> %Arena.Config{owner: :my_test, id: {:my_test}, context: %{}, callbacks: []}

      # Add context
      config = Arena.Config.put(config, :pubsub_name, MyApp.PubSub.Test)

      # Add a callback for child processes
      config = Arena.Config.add_callback(config, {Ecto.Adapters.SQL.Sandbox, :allow, [repo: MyApp.Repo]})

      # Create a child config (for spawned processes)
      child_config = Arena.Config.child(config, MyServer)
      #=> %Arena.Config{owner: :my_test, id: {:my_test, MyServer}, ...}

      # Access current config from process dictionary
      config = Arena.Config.current()

  ## Process Dictionary Storage

  Configs are stored in the process dictionary under the key `:arena_config` for ergonomic
  access. All functions accept an explicit config as the first argument, but also provide
  0-arity versions that use `current/0` for convenience.
  """

  @enforce_keys [:owner, :id]
  defstruct [:owner, :id, context: %{}, callbacks: []]

  @type t :: %__MODULE__{
          owner: atom(),
          id: tuple(),
          context: map(),
          callbacks: list({module(), atom()} | {module(), atom(), keyword()})
        }

  @allowed_keys [:owner, :id, :callbacks]

  @doc """
  Creates a new Config from an owner atom or test context map.

  ## Examples

      # From atom
      Arena.Config.new(:my_test)
      #=> %Arena.Config{owner: :my_test, id: {:my_test}, context: %{}, callbacks: []}

      # From test context (ExUnit)
      Arena.Config.new(%{test: :my_test, module: MyApp.SomeTest})
      #=> %Arena.Config{owner: :"Elixir.MyApp.SomeTest.my_test", id: {:"Elixir.MyApp.SomeTest.my_test"}, ...}

      # With initial context
      Arena.Config.new(:my_test, context: %{pubsub_name: MyPubSub})
  """
  @spec new(atom() | map(), keyword()) :: t()
  def new(owner_or_context, opts \\ [])

  def new(%{test: test, module: module} = _context, opts) do
    owner =
      [Atom.to_string(module), Atom.to_string(test)]
      |> Enum.join(".")
      |> String.slice(-200..-1//1)
      |> String.to_atom()

    new(owner, opts)
  end

  def new(owner, opts) when is_atom(owner) and is_list(opts) do
    id = {owner}
    context = Keyword.get(opts, :context, %{})
    callbacks = Keyword.get(opts, :callbacks, [])

    %__MODULE__{
      owner: owner,
      id: id,
      context: context,
      callbacks: callbacks
    }
  end

  @doc """
  Returns the default Config used when not in a test context.

  This is useful for global processes that run outside of tests.

  ## Examples

      Arena.Config.defaults()
      #=> %Arena.Config{owner: :arena_global, id: {:arena_global}, ...}
  """
  @spec defaults() :: t()
  def defaults do
    %__MODULE__{
      owner: :arena_global,
      id: {:arena_global},
      context: %{},
      callbacks: []
    }
  end

  @doc """
  Returns the current Config from the process dictionary.

  Falls back to `defaults/0` if no config is stored.

  ## Examples

      # Without stored config
      Arena.Config.current()
      #=> %Arena.Config{owner: :arena_global, ...}

      # After storing a config
      config = Arena.Config.new(:my_test)
      Arena.Config.store(config)
      Arena.Config.current()
      #=> %Arena.Config{owner: :my_test, ...}
  """
  @spec current() :: t()
  def current do
    Process.get(:arena_config, defaults())
  end

  @doc """
  Stores the config in the process dictionary and returns it.

  This enables ergonomic access via `current/0` and 0-arity helper functions.

  ## Examples

      config = Arena.Config.new(:my_test)
      Arena.Config.store(config)
      #=> %Arena.Config{owner: :my_test, ...}

      Arena.Config.current()
      #=> %Arena.Config{owner: :my_test, ...}
  """
  @spec store(t()) :: t()
  def store(%__MODULE__{} = config) do
    Process.put(:arena_config, config)
    config
  end

  @doc """
  Gets a value from the config's context or from a struct field.

  For keys in `#{inspect(@allowed_keys)}`, returns the struct field value.
  For other keys, looks up the value in the `context` map.

  ## Examples

      config = Arena.Config.new(:my_test)
      Arena.Config.get(config, :owner)
      #=> :my_test

      config = Arena.Config.put(config, :pubsub_name, MyPubSub)
      Arena.Config.get(config, :pubsub_name)
      #=> MyPubSub

      # 0-arity version uses current()
      Arena.Config.store(config)
      Arena.Config.get(:pubsub_name)
      #=> MyPubSub
  """
  @spec get(t(), atom()) :: any()
  @spec get(atom()) :: any()
  def get(key) when is_atom(key) do
    get(current(), key)
  end

  def get(%__MODULE__{} = config, key) when key in @allowed_keys do
    Map.get(config, key)
  end

  def get(%__MODULE__{} = config, key) do
    Map.fetch!(config.context, key)
  end

  @doc """
  Puts a value into the config's context.

  Protected keys (#{inspect(@allowed_keys)}) cannot be set this way - they must be
  set during creation or via specific functions.

  After putting a value, callbacks are executed (this happens when child processes
  are configured).

  ## Examples

      config = Arena.Config.new(:my_test)
      config = Arena.Config.put(config, :pubsub_name, MyPubSub)
      #=> %Arena.Config{..., context: %{pubsub_name: MyPubSub}}

      # 0-arity version uses and updates current()
      Arena.Config.store(config)
      Arena.Config.put(:custom_key, :value)
      #=> %Arena.Config{..., context: %{pubsub_name: MyPubSub, custom_key: :value}}
  """
  @spec put(t(), atom(), any()) :: t()
  @spec put(atom(), any()) :: t()
  def put(key, value) when is_atom(key) do
    current()
    |> put(key, value)
    |> store()
  end

  def put(%__MODULE__{} = _config, key, _value) when key in @allowed_keys do
    raise ArgumentError, "Cannot manually set protected key #{inspect(key)}. Use Config API functions."
  end

  def put(%__MODULE__{} = config, key, value) do
    new_config = %{config | context: Map.put(config.context, key, value)}
    execute_callbacks(new_config)
    new_config
  end

  @doc """
  Adds a callback to be executed when child processes are configured.

  Callbacks are tuples of `{module, function}` or `{module, function, opts}`.
  They are executed in order when `execute_callbacks/1` is called.

  ## Examples

      config = Arena.Config.new(:my_test)
      config = Arena.Config.add_callback(config, {MyModule, :setup})
      config = Arena.Config.add_callback(config, {Ecto.Adapters.SQL.Sandbox, :allow, [repo: MyRepo]})

      # 1-arity version uses and updates current()
      Arena.Config.add_callback({MyModule, :init})
  """
  @spec add_callback(t(), {module(), atom()} | {module(), atom(), keyword()}) :: t()
  @spec add_callback({module(), atom()} | {module(), atom(), keyword()}) :: t()
  def add_callback(callback) when is_tuple(callback) do
    add_callback(current(), callback)
  end

  def add_callback(%__MODULE__{} = config, callback) when tuple_size(callback) in [2, 3] do
    new_config = %{config | callbacks: config.callbacks ++ [callback]}
    store(new_config)
  end

  @doc """
  Executes all callbacks registered in the config.

  Callbacks are called with the config as the first argument, and optional opts
  as the second argument.

  ## Examples

      config = Arena.Config.new(:my_test)
      |> Arena.Config.add_callback({MyModule, :setup})
      |> Arena.Config.add_callback({MyModule, :setup_with_opts, [key: :value]})

      Arena.Config.execute_callbacks(config)
      # Calls:
      # - MyModule.setup(config)
      # - MyModule.setup_with_opts(config, [key: :value])
  """
  @spec execute_callbacks(t()) :: :ok
  def execute_callbacks(%__MODULE__{} = config) do
    Enum.each(config.callbacks, fn
      {m, f} -> apply(m, f, [config])
      {m, f, opts} -> apply(m, f, [config, opts])
    end)
  end

  @doc """
  Creates a child config for a spawned process.

  Child configs inherit the parent's owner, context, and callbacks, but get a
  new hierarchical `id` that tracks their position in the process tree.

  If the child_key is already the last element of the parent's id tuple, returns
  the parent unchanged (idempotent).

  ## Examples

      parent = Arena.Config.new(:my_test)
      #=> %Arena.Config{id: {:my_test}, ...}

      child = Arena.Config.child(parent, MyServer)
      #=> %Arena.Config{id: {:my_test, MyServer}, ...}

      grandchild = Arena.Config.child(child, :instance_1)
      #=> %Arena.Config{id: {:my_test, MyServer, :instance_1}, ...}

      # Idempotent - if child_key already last element
      Arena.Config.child(child, MyServer)
      #=> %Arena.Config{id: {:my_test, MyServer}, ...}
  """
  @spec child(t(), any()) :: t()
  def child(%__MODULE__{id: parent_id} = config, child_key) do
    last_element = elem(parent_id, tuple_size(parent_id) - 1)

    case last_element == child_key do
      true -> config
      false -> %{config | id: Tuple.insert_at(parent_id, tuple_size(parent_id), child_key)}
    end
  end

  @doc """
  Returns the root owner from the config's id tuple.

  The root is always the first element of the id tuple.

  ## Examples

      config = Arena.Config.new(:my_test)
      |> Arena.Config.child(MyServer)
      |> Arena.Config.child(:instance_1)

      Arena.Config.root(config)
      #=> :my_test

      # 0-arity version uses current()
      Arena.Config.store(config)
      Arena.Config.root()
      #=> :my_test
  """
  @spec root(t()) :: atom()
  @spec root() :: atom()
  def root do
    root(current())
  end

  def root(%__MODULE__{id: id}) do
    elem(id, 0)
  end

  @doc """
  Converts the config's id to a human-readable string.

  Useful for debugging and logging.

  ## Examples

      config = Arena.Config.new(:my_test)
      |> Arena.Config.child(MyApp.Server)
      |> Arena.Config.child(:instance_1)

      Arena.Config.to_string(config)
      #=> "my_test/MyApp.Server/instance_1"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{id: id}) do
    id
    |> Tuple.to_list()
    |> Enum.map_join("/", fn
      value when is_atom(value) -> Atom.to_string(value)
      string -> Kernel.to_string(string)
    end)
    |> String.replace("Elixir.", "")
  end
end
