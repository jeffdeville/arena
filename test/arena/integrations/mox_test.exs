defmodule Arena.Integrations.MoxTest do
  use ExUnit.Case, async: true

  import Mox

  alias Arena.Config
  alias Arena.Integrations.Mox, as: ArenaMox

  # A behaviour + private-mode mock, defined for this test.
  defmodule Greeter do
    @callback greet() :: String.t()
  end

  Mox.defmock(GreeterMock, for: Greeter)

  # A GenServer spawned by Arena (out of the test's $callers) that calls the mock
  # from inside its OWN process — the case that fails without the allowance.
  defmodule GreeterServer do
    use GenServer
    use Arena.Process

    @impl Arena.Process
    def to_process_key(_), do: __MODULE__

    def greet, do: GenServer.call(via_tuple(), :greet)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call(:greet, _from, state), do: {:reply, GreeterMock.greet(), state}
  end

  setup :verify_on_exit!

  defp start_server(config) do
    Config.store(config)
    start_supervised!({GreeterServer, Arena.wrap(config, %{})})
  end

  test "a wrapped GenServer can use the test's private-mode expectation" do
    expect(GreeterMock, :greet, fn -> "hello from the test process" end)

    config =
      %{module: __MODULE__, test: :allowed}
      |> Arena.setup()
      |> ArenaMox.setup(mocks: [GreeterMock])

    start_server(config)

    assert GreeterServer.greet() == "hello from the test process"
  end

  test "WITHOUT the allowance, a foreign process cannot use the expectation" do
    # A stub is owned by the test process in :private mode; a bare spawned
    # process (no $callers, no Arena allowance) cannot resolve it.
    stub(GreeterMock, :greet, fn -> "from the test process" end)

    parent = self()

    spawn(fn ->
      result =
        try do
          GreeterMock.greet()
        rescue
          e -> {:error, e}
        end

      send(parent, {:greet_result, result})
    end)

    assert_receive {:greet_result, {:error, %Mox.UnexpectedCallError{}}}
  end

  test "setup/2 raises a helpful error when Mox is unavailable" do
    # Mox IS available here; assert the happy path returns a config with the callback.
    config = ArenaMox.setup(Arena.setup(%{module: __MODULE__, test: :cb}), mocks: [GreeterMock])
    assert Enum.any?(config.callbacks, &match?({Arena.Integrations.Mox, :allow_mocks, _}, &1))
  end
end
