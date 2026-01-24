defmodule Arena.Wrapped do
  @moduledoc """
  An envelope that carries both Arena configuration and process arguments.

  `Arena.Wrapped` (formerly known as Wireable in Belay.Wiring) is a simple container
  that wraps the arguments passed to a process's `start_link/1` function along with
  the Arena configuration needed for test isolation.

  ## Purpose

  When starting a process in an Arena-managed test, you need to pass two things:
  1. The actual arguments the process needs (business logic)
  2. The Arena config for infrastructure setup (testing plumbing)

  Wrapped keeps these separate and clear, acting as an envelope that the process
  unwraps during initialization.

  ## Structure

  - `config` - The `Arena.Config` containing infrastructure details
  - `input` - The actual arguments the process needs (opaque to Arena)

  ## Examples

      # Create a wrapped envelope
      config = Arena.Config.new(:my_test)
      wrapped = Arena.Wrapped.new(config, [:initial, :state])
      #=> %Arena.Wrapped{config: %Arena.Config{...}, input: [:initial, :state]}

      # Pass to a GenServer
      {:ok, pid} = MyServer.start_link(wrapped)

      # The server unwraps it automatically (via Arena.Process macro)
      # - Extracts config for Arena setup
      # - Passes input to your init/1 function
  """

  @enforce_keys [:config, :input]
  defstruct [:config, :input]

  @type t :: %__MODULE__{
          config: Arena.Config.t(),
          input: any()
        }

  @doc """
  Creates a new Wrapped envelope containing config and input.

  ## Examples

      config = Arena.Config.new(:my_test)
      Arena.Wrapped.new(config, :my_args)
      #=> %Arena.Wrapped{config: %Arena.Config{...}, input: :my_args}

      # Input can be any term
      Arena.Wrapped.new(config, %{key: :value})
      Arena.Wrapped.new(config, [:list, :of, :things])
      Arena.Wrapped.new(config, nil)
  """
  @spec new(Arena.Config.t(), any()) :: t()
  def new(%Arena.Config{} = config, input \\ nil) do
    %__MODULE__{
      config: config,
      input: input
    }
  end
end
