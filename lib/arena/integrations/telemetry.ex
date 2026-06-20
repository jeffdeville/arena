defmodule Arena.Integrations.Telemetry do
  @moduledoc """
  Per-test capture of [`:telemetry`](https://hexdocs.pm/telemetry) events.

  `:telemetry` handlers are **global** (keyed by handler id), so two async tests
  that each attach a capture handler for the same event collide. `capture/2`
  attaches a handler whose id is scoped to the test's Arena owner (so concurrent
  tests don't clash), forwards the matched events to the current process, and
  detaches on test exit.

  ## Usage

      setup do
        Arena.Integrations.Telemetry.capture([[:my_app, :worker, :done]])
        :ok
      end

      test "emits a completion event" do
        # ... exercise the code that calls :telemetry.execute/3 ...
        assert_receive {:telemetry, [:my_app, :worker, :done], %{count: 1}, _metadata}
      end

  A single event may be passed directly (`capture([:my_app, :worker, :done])`) or
  a list of events (`capture([[:a, :b], [:c, :d]])`). Forwarded messages are
  `{:telemetry, event_name, measurements, metadata}`.

  ## Options

    * `:to` — the pid to forward events to. Defaults to `self()` (the test).

  Requires the `:telemetry` application (an optional dependency).
  """

  alias Arena.Config

  @doc """
  Attaches a per-test telemetry handler for `events`, forwarding each to the
  current process (or `opts[:to]`) and detaching on test exit. Returns `:ok`.
  """
  @spec capture(list(), keyword()) :: :ok
  def capture(events, opts \\ []) when is_list(events) do
    unless telemetry_available?() do
      raise RuntimeError, """
      :telemetry is not available.

      To use Arena.Integrations.Telemetry, add it to your dependencies:

          {:telemetry, "~> 1.0"}
      """
    end

    to = Keyword.get(opts, :to, self())
    id = {__MODULE__, Config.current().owner, System.unique_integer([:positive])}

    :telemetry.attach_many(id, normalize(events), &__MODULE__.__handle__/4, %{to: to})
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)

    :ok
  end

  @doc false
  def __handle__(event, measurements, metadata, %{to: to}) do
    send(to, {:telemetry, event, measurements, metadata})
  end

  # A single event ([:a, :b]) vs a list of events ([[:a, :b], [:c, :d]]).
  defp normalize([first | _] = events) when is_atom(first), do: [events]
  defp normalize(events), do: events

  defp telemetry_available?, do: Code.ensure_loaded?(:telemetry)
end
