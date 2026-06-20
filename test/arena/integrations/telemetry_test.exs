defmodule Arena.Integrations.TelemetryTest do
  use ExUnit.Case, async: true

  alias Arena.Integrations.Telemetry, as: ArenaTelemetry

  setup do
    # A per-test owner so the handler id is unique across async tests.
    Arena.Config.new(:"telemetry_#{System.unique_integer([:positive])}") |> Arena.Config.store()
    :ok
  end

  test "forwards a single matched event to the test process" do
    event = [:arena, :telemetry_test, :single]
    ArenaTelemetry.capture(event)

    :telemetry.execute(event, %{count: 1}, %{foo: :bar})

    assert_receive {:telemetry, ^event, %{count: 1}, %{foo: :bar}}
  end

  test "forwards multiple events, and ignores unmatched ones" do
    a = [:arena, :telemetry_test, :a]
    b = [:arena, :telemetry_test, :b]
    ArenaTelemetry.capture([a, b])

    :telemetry.execute(b, %{n: 2}, %{})
    :telemetry.execute([:arena, :telemetry_test, :unwatched], %{n: 9}, %{})
    :telemetry.execute(a, %{n: 1}, %{})

    assert_receive {:telemetry, ^b, %{n: 2}, _}
    assert_receive {:telemetry, ^a, %{n: 1}, _}
    refute_received {:telemetry, [:arena, :telemetry_test, :unwatched], _, _}
  end

  test ":to forwards to another process" do
    event = [:arena, :telemetry_test, :routed]
    parent = self()
    target = spawn(fn -> receive do: (msg -> send(parent, {:got, msg})) end)

    ArenaTelemetry.capture(event, to: target)
    :telemetry.execute(event, %{}, %{})

    assert_receive {:got, {:telemetry, ^event, _, _}}
  end
end
