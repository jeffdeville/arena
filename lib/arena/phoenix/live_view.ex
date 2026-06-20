defmodule Arena.Phoenix.LiveView do
  @moduledoc """
  A Phoenix LiveView `on_mount` hook that stores the per-test `Arena.Config`
  inside the **connected** LiveView process (and runs its callbacks, so the
  process is authorized onto the test's Ecto sandbox connection).

  Wire it as a global hook in your `MyAppWeb, :live_view` (and any other
  LiveView) macro:

      def live_view do
        quote do
          use Phoenix.LiveView, layout: {MyAppWeb.Layouts, :app}
          on_mount Arena.Phoenix.LiveView
          # ... your other on_mount hooks
        end
      end

  It reads the config that `Arena.Phoenix.put_config/2` stashed on the conn —
  `Phoenix.LiveViewTest` threads `conn.private` into the connected mount's
  `connect_info`, so the hook finds it at
  `socket.private.connect_info.private.arena_config`. The hook runs **before**
  `mount/3`, so the view's own subscriptions and `via_tuple()` calls resolve to
  the per-test owner.

  In dev/prod nothing injects a config, so the hook stores nothing and the
  LiveView runs exactly as before. Because it runs the config's callbacks, it
  also grants the connected LiveView Ecto sandbox access — you can drop the
  separate `Phoenix.Ecto.SQL.Sandbox` on_mount for `Phoenix.LiveViewTest` suites
  (browser/Wallaby suites still need it; see `docs/testing-phoenix.md`).
  """

  @doc """
  The on_mount callback. Stores the injected `Arena.Config` (if any) in the
  LiveView process and returns `{:cont, socket}` unconditionally.
  """
  @spec on_mount(atom(), map(), map(), socket) :: {:cont, socket} when socket: map()
  def on_mount(_name, _params, _session, socket) do
    Arena.Phoenix.store_from_socket(socket)
    {:cont, socket}
  end
end
