defmodule Arena.Integrations.PubSub do
  @moduledoc """
  Integration with Phoenix.PubSub for isolated pub/sub messaging.

  This integration creates a unique PubSub server for each test, ensuring that
  messages published during one test don't leak into other tests. This is essential
  for async testing with process-based messaging.

  ## How It Works

  1. Arena.Integrations.PubSub.setup/2 starts a PubSub server with a unique name
  2. The PubSub name is stored in the config's context
  3. All processes spawned in the test can access the PubSub name via config
  4. The PubSub server is supervised by the test process and stops when the test ends

  ## Usage

      # In your test case setup
      setup context do
        config = Arena.setup(context)
        |> Arena.Integrations.PubSub.setup()

        {:ok, arena: config}
      end

      # Access PubSub in your GenServers
      defmodule MyServer do
        use GenServer
        use Arena.Process

        def init(args) do
          pubsub_name = Arena.Config.get(:pubsub_name)
          Phoenix.PubSub.subscribe(pubsub_name, "my_topic")
          {:ok, args}
        end
      end

      # Publish messages in tests
      test "server receives messages", %{arena: config} do
        pubsub_name = Arena.Config.get(config, :pubsub_name)
        {:ok, _pid} = MyServer.start_link(Arena.wrap(config, :state))

        Phoenix.PubSub.broadcast(pubsub_name, "my_topic", {:hello, :world})
        # MyServer will receive the message
      end

  ## Custom PubSub Name

      # Use a specific name instead of auto-generated
      config = Arena.setup(:my_test)
      |> Arena.Integrations.PubSub.setup(name: MyCustomPubSub)

  ## Under the Hood

  The PubSub server is started with `start_link/1` in the test process context,
  so it will be automatically cleaned up when the test exits. The server name
  is derived from the test owner atom to ensure uniqueness.
  """

  alias Arena.Config

  @doc """
  Sets up a Phoenix.PubSub server for the test.

  Starts a PubSub server with a unique name and stores it in the config's context
  under the `:pubsub_name` key.

  ## Options

  - `:name` - (optional) Custom name for the PubSub server. If not provided,
    generates a name based on the config owner.

  ## Examples

      # Auto-generated name
      config = Arena.setup(:my_test)
      |> Arena.Integrations.PubSub.setup()

      Arena.Config.get(config, :pubsub_name)
      #=> MyTest.PubSub (or similar)

      # Custom name
      config = Arena.setup(:my_test)
      |> Arena.Integrations.PubSub.setup(name: MyCustomPubSub)

      Arena.Config.get(config, :pubsub_name)
      #=> MyCustomPubSub
  """
  @spec setup(Config.t(), keyword()) :: Config.t()
  def setup(%Config{} = config, opts \\ []) do
    unless phoenix_pubsub_available?() do
      raise RuntimeError, """
      Phoenix.PubSub is not available.

      To use Arena.Integrations.PubSub, you need to add Phoenix.PubSub to your dependencies:

          {:phoenix_pubsub, "~> 2.0", only: :test}
      """
    end

    # Generate or use custom PubSub name
    pubsub_name =
      case Keyword.get(opts, :name) do
        nil ->
          # Generate name from owner
          owner = Config.get(config, :owner)
          Module.concat(owner, PubSub)

        custom_name ->
          custom_name
      end

    # Start the PubSub server
    # It will be supervised by the test process via start_supervised!
    # We don't use a callback here because we want PubSub available immediately
    start_pubsub(pubsub_name)

    # Store the PubSub name in config context
    Config.put(config, :pubsub_name, pubsub_name)
  end

  defp start_pubsub(name) do
    # Start PubSub server supervised by the test process
    # Uses ExUnit.Callbacks.start_supervised! which can be called from setup callbacks
    if phoenix_pubsub_available?() do
      ExUnit.Callbacks.start_supervised!({Phoenix.PubSub, name: name})
    end

    :ok
  end

  defp phoenix_pubsub_available? do
    Code.ensure_loaded?(Phoenix.PubSub)
  end
end
