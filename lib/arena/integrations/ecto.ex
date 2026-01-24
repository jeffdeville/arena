defmodule Arena.Integrations.Ecto do
  @moduledoc """
  Integration with Ecto.Adapters.SQL.Sandbox for database isolation.

  This integration enables async tests to share database connections across spawned
  processes. When a test spawns a GenServer, that GenServer needs access to the test's
  database transaction. Arena.Integrations.Ecto sets up callbacks that authorize child
  processes to access the parent's sandbox connection.

  ## How It Works

  1. Test process checks out a sandbox connection
  2. Arena.Integrations.Ecto.setup/2 adds an authorization callback to the config
  3. When child processes initialize, the callback executes
  4. Ecto.Adapters.SQL.Sandbox.allow/3 grants the child access

  ## Usage

      # In your DataCase setup
      setup context do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
        Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})

        config = Arena.setup(context)
        |> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)

        {:ok, arena: config}
      end

      # Now spawned processes can access the database
      test "server can query database", %{arena: config} do
        {:ok, pid} = MyServer.start_link(Arena.wrap(config, args))
        # MyServer can now run Ecto queries
      end

  ## Multiple Repositories

      config = Arena.setup(context)
      |> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
      |> Arena.Integrations.Ecto.setup(repo: MyApp.OtherRepo)

  ## Options

  - `:repo` - (required) The Ecto repository module
  - `:ancestor_pid` - (optional) The process that owns the sandbox connection.
    Defaults to `self()` (the test process).
  """

  alias Arena.Config

  @doc """
  Adds Ecto Sandbox authorization to an Arena config.

  This function adds a callback that will be executed when child processes are
  spawned. The callback authorizes the child to use the test's database connection.

  ## Options

  - `:repo` - (required) The Ecto repository module
  - `:ancestor_pid` - (optional) The process that owns the sandbox connection.
    Defaults to `self()`.

  ## Examples

      # Basic usage
      config = Arena.setup(:my_test)
      |> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)

      # With explicit ancestor PID
      config = Arena.setup(:my_test)
      |> Arena.Integrations.Ecto.setup(
        repo: MyApp.Repo,
        ancestor_pid: self()
      )

      # Multiple repos
      config = Arena.setup(:my_test)
      |> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
      |> Arena.Integrations.Ecto.setup(repo: MyApp.Analytics.Repo)
  """
  @spec setup(Config.t(), keyword()) :: Config.t()
  def setup(%Config{} = config, opts) do
    unless ecto_sandbox_available?() do
      raise RuntimeError, """
      Ecto.Adapters.SQL.Sandbox is not available.

      To use Arena.Integrations.Ecto, you need to add Ecto SQL to your dependencies:

          {:ecto_sql, "~> 3.0", only: :test}
      """
    end

    repo = Keyword.fetch!(opts, :repo)
    ancestor_pid = Keyword.get(opts, :ancestor_pid, self())

    callback = {__MODULE__, :allow_sandbox, [repo: repo, ancestor_pid: ancestor_pid]}
    Config.add_callback(config, callback)
  end

  @doc false
  def allow_sandbox(_config, opts) do
    repo = Keyword.fetch!(opts, :repo)
    ancestor_pid = Keyword.fetch!(opts, :ancestor_pid)

    if ecto_sandbox_available?() do
      apply(Ecto.Adapters.SQL.Sandbox, :allow, [repo, ancestor_pid, self()])
    end

    :ok
  end

  defp ecto_sandbox_available? do
    Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox)
  end
end
