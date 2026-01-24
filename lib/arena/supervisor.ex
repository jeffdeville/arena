defmodule Arena.Supervisor do
  @moduledoc """
  Macro for Supervisors to integrate with Arena's test isolation system.

  `Arena.Supervisor` provides a simpler integration than `Arena.Process` since
  supervisors don't need Registry lookup or via tuples. The macro simply intercepts
  `start_link` and `init` to unwrap the Arena configuration and make it available
  to child processes.

  ## What It Does

  When you `use Arena.Supervisor`, the macro injects:

  1. **start_link/1** - Accepts `Arena.Wrapped` and calls Supervisor.start_link
  2. **init/1 wrapper** - Intercepts init to configure Arena, then calls your init
  3. Config storage in process dictionary for child processes to access

  ## Usage

      defmodule MyApp.MySupervisor do
        use Supervisor
        use Arena.Supervisor

        def init(opts) do
          # Get current config to wrap children
          config = Arena.Config.current()

          children = [
            # Wrap each child that needs Arena config
            {MyWorker, Arena.wrap(config, worker_args)},
            {AnotherWorker, Arena.wrap(config, other_args)}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      # In tests
      config = Arena.setup(:my_test)
      {:ok, sup_pid} = MySupervisor.start_link(Arena.wrap(config, :init_args))

  ## Supervisor vs Process

  Supervisors are simpler than GenServers in Arena:

  - No Registry registration (supervisors are usually not looked up by name)
  - No via_tuple needed
  - No get_pid/alive? helpers
  - Just unwrap config, store it, and pass to user's init

  ## Examples

      # Basic supervisor
      defmodule MyApp.WorkerSupervisor do
        use Supervisor
        use Arena.Supervisor

        def init(_opts) do
          config = Arena.Config.current()

          children = [
            {MyApp.Worker, Arena.wrap(config, :worker_state)}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      # Dynamic supervisor
      defmodule MyApp.DynamicSupervisor do
        use DynamicSupervisor
        use Arena.Supervisor

        def init(_opts) do
          DynamicSupervisor.init(strategy: :one_for_one)
        end

        def start_worker(sup, args) do
          config = Arena.Config.current()
          spec = {MyApp.Worker, Arena.wrap(config, args)}
          DynamicSupervisor.start_child(sup, spec)
        end
      end

  ## Important Notes

  - Supervisors don't automatically wrap children - you must explicitly wrap them
  - Use `Arena.Config.current()` in your init to get the config
  - The supervisor stores a child config in its process dictionary
  - Children can access this via `Arena.Config.current()` if needed
  """

  defmacro __using__(_opts) do
    quote location: :keep do
      alias Arena.Config
      alias Arena.Wrapped

      @doc """
      Starts the Supervisor with Arena configuration.

      Accepts an `Arena.Wrapped` struct containing both the config and init args.

      ## Examples

          config = Arena.Config.new(:my_test)
          wrapped = Arena.Wrapped.new(config, :init_args)
          {:ok, pid} = MySupervisor.start_link(wrapped)
      """
      @spec start_link(Wrapped.t()) :: Supervisor.on_start()
      def start_link(%Wrapped{} = wrapped) do
        Supervisor.start_link(__MODULE__, wrapped)
      end

      @doc """
      Wraps the user's init/1 to configure Arena before calling it.

      This is injected by the macro and intercepts the init call to:
      1. Extract the config from Wrapped
      2. Create a child config with the supervisor's module name
      3. Store config in process dictionary
      4. Execute callbacks
      5. Call the user's init/1 with the unwrapped input

      The user's init/1 should be defined to accept the unwrapped input.
      """
      def init(%Wrapped{} = wrapped) do
        configure_arena(wrapped)
        init(wrapped.input)
      end

      @doc false
      defp configure_arena(%Wrapped{config: parent_config}) do
        parent_config
        |> Config.child(__MODULE__)
        |> Config.store()
        |> Config.execute_callbacks()
      end
    end
  end
end
