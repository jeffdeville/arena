defmodule Arena.Phoenix do
  @moduledoc """
  Seams for using Arena with Phoenix tests (`Phoenix.ConnTest`,
  `Phoenix.LiveViewTest`, `Phoenix.ChannelTest`).

  These helpers are **dependency-free** — they operate on the plain socket/conn
  maps Phoenix gives you, so this module pulls in no Phoenix dependency.

  ## Why you need them

  `Phoenix.LiveViewTest` and `Phoenix.ChannelTest` run **in-process** (no real
  transport), so they are Arena-eligible and run `async: true`. But a *connected*
  LiveView, or a channel after `join/3`, runs in a **separate process** Phoenix
  spawns for you — it doesn't carry the test's `Arena.Config`. These helpers
  deliver the config into that process so `via_tuple()` lookups, per-test PubSub,
  and the Ecto sandbox all resolve correctly. See `docs/testing-phoenix.md`.

  ## The three seams

      # 1. In your ConnCase setup — stash the per-test config on the conn:
      conn = Arena.Phoenix.put_config(Phoenix.ConnTest.build_conn(), config)

      # 2. In your `MyAppWeb, :live_view` macro — a global on_mount hook stores it
      #    inside the connected LiveView process (see Arena.Phoenix.LiveView):
      on_mount Arena.Phoenix.LiveView

      # 3. In a channel's join/3 (config threaded in via connect_info -> assigns):
      def join(_topic, _params, socket) do
        Arena.Phoenix.store_from_socket(socket)
        ...
      end

  `put_config/2` works because `Phoenix.LiveViewTest` threads `conn.private` into
  the connected mount's `connect_info` (it's the pruned conn). In dev/prod nothing
  injects a config, so every seam is a no-op.

  See also `Arena.Phoenix.PubSub` for resolving a per-test `Phoenix.PubSub` server.
  """

  alias Arena.Config

  @doc """
  Stashes the per-test `Arena.Config` on `conn.private[:arena_config]` — the
  injection seam the LiveView/Channel processes read it back from. Returns the
  conn. Works on any map/struct with a `:private` map (a `Plug.Conn`, or a test
  double), so no `Plug` dependency is needed.
  """
  @spec put_config(conn, Config.t()) :: conn when conn: %{private: map()}
  def put_config(%{private: private} = conn, %Config{} = config) do
    %{conn | private: Map.put(private, :arena_config, config)}
  end

  @doc """
  Returns the injected `Arena.Config` for a socket or conn, or `nil`.

  Checks, in order: `socket.assigns.arena_config` (the channel seam — assigned in
  `connect/3`), `*.private.arena_config` (a conn, or a LiveView disconnected
  mount), and `*.private.connect_info.private.arena_config` (a LiveView connected
  mount, whose `connect_info` is the pruned conn in tests). `nil` for the real
  production shapes.
  """
  @spec arena_config(map()) :: Config.t() | nil
  def arena_config(socket_or_conn) do
    from_assigns(socket_or_conn) ||
      from_private(socket_or_conn) ||
      from_connect_info(socket_or_conn)
  end

  @doc """
  Stores the injected config in the CURRENT process and runs its integration
  callbacks (e.g. the Ecto sandbox `allow`), making this process part of the
  test's isolation. Call it at the top of a channel `join/3` (and it's what
  `Arena.Phoenix.LiveView`'s `on_mount` hook does for a connected LiveView).

  A no-op when no config is present (production). Returns `:ok`.
  """
  @spec store_from_socket(map()) :: :ok
  def store_from_socket(socket), do: store(arena_config(socket))

  @doc false
  def store(%Config{} = config) do
    config
    |> Config.store()
    |> Config.execute_callbacks()

    :ok
  end

  def store(_), do: :ok

  defp from_assigns(%{assigns: %{arena_config: %Config{} = c}}), do: c
  defp from_assigns(_), do: nil

  defp from_private(%{private: %{arena_config: %Config{} = c}}), do: c
  defp from_private(_), do: nil

  defp from_connect_info(%{private: %{connect_info: %{private: %{arena_config: %Config{} = c}}}}),
    do: c

  defp from_connect_info(_), do: nil
end
