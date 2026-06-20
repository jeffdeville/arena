# Testing Phoenix (LiveView & Channels) with Arena

This is the non-obvious part of using Arena in a Phoenix app. The short version:

> `Phoenix.ConnTest`, `Phoenix.LiveViewTest`, and `Phoenix.ChannelTest` all run
> **in-process** — there is no real Bandit/Cowboy worker or browser socket — so
> they are Arena-eligible and run `async: true`. The only catch is that a
> **connected** LiveView/Channel runs in a *separate process* that Phoenix spawns
> for you, so you have to deliver the per-test `Arena.Config` into that process.
> There are two clean channels for doing it, and both are already how the Ecto
> sandbox reaches the same process.

If you skip this, things mostly work — until you try to isolate `Phoenix.PubSub`
per test, at which point messages silently vanish. That failure mode is covered
at the end.

---

## 1. Why Phoenix tests are Arena-eligible (and async)

The real HTTP-boundary limitation (a process that doesn't inherit the test's
process dictionary) applies to a **real** transport: a Bandit worker handling a
production request, or a browser WebSocket in Wallaby/Playwright. The Phoenix
*test* helpers don't use one:

- `Phoenix.ConnTest` / controller & webhook tests dispatch the conn through the
  endpoint **inline in the test process** (`Plug.Test`).
- `Phoenix.LiveViewTest` renders the disconnected mount inline, then spawns the
  connected LiveView as a normal BEAM process under the ExUnit test supervisor.
- `Phoenix.ChannelTest` runs the channel in-process too.

So all three keep the test's process lineage and are isolatable with Arena at
`async: true`. (Only Wallaby/Playwright cross a real boundary — see §6.)

## 2. The LiveView lifecycle: two mounts, two processes

`Phoenix.LiveViewTest.live(conn, path)` mounts the view **twice**:

1. **Disconnected mount** — a normal `get(conn, path)`. `mount/3` runs **in the
   test process**. `connected?(socket)` is `false`; most LiveViews skip work here.
2. **Connected mount** — `Phoenix.LiveViewTest` starts a `Phoenix.LiveView.Channel`
   GenServer under the **ExUnit test supervisor** and sends it the mount. `mount/3`
   (and every `on_mount` hook) runs **in that channel process**. `connected?` is
   `true`; this is where subscriptions, `Arena.via_tuple()` lookups, etc. happen.

Two facts about the connected process make it reachable (both source-verified
against `phoenix_live_view`):

- Its spawn-tree parent (`$ancestors`) is the **test supervisor**, not the test
  process — so "read my parent's process dictionary" does **not** find the test.
- But the channel sets `Process.put(:"$callers", [test_pid])` from the join
  params' `"caller"` (`phoenix_live_view/.../channel.ex`). So the **test process
  is in `$callers`** — the same caller-tracking chain the Ecto sandbox and Mox
  use.
- In tests, the connected mount's `connect_info` is the **pruned `Plug.Conn`**
  (`%{conn | resp_body: nil, resp_headers: []}` — `conn.private` is kept intact),
  available as `socket.private.connect_info` during mount and on_mount hooks and
  dropped immediately after.

That gives you two ways to deliver the config to the connected process.

## 3. The recipe — deliver the config via an `on_mount` hook

This mirrors exactly how `Phoenix.Ecto.SQL.Sandbox` grants the connected LiveView
DB access (`assign_new(:phoenix_ecto_sandbox, fn -> get_connect_info(socket, :user_agent) end)`
then `allow/2` in an `on_mount`).

### 3a. The case template stashes the config on the conn

```elixir
# test/support/conn_case.ex
setup tags do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
  on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

  config =
    tags
    |> Arena.setup()
    |> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
    |> Arena.Integrations.PubSub.setup()   # stores :pubsub_name in context
    |> Arena.Config.store()                # store in the TEST process too

  # The injection seam: LiveViewTest threads conn.private into the connected
  # mount's connect_info, so stashing the config here delivers it.
  conn = Phoenix.ConnTest.build_conn() |> Plug.Conn.put_private(:arena_config, config)

  {:ok, conn: conn, config: config}
end
```

### 3b. A global `on_mount` hook stores it inside the connected LiveView

```elixir
defmodule MyAppWeb.LiveArena do
  @moduledoc "Stores the per-test Arena.Config in the connected LiveView process."

  def on_mount(:default, _params, _session, socket) do
    case arena_config(socket) do
      %Arena.Config{} = config -> Arena.Config.store(config)
      _ -> :ok
    end

    {:cont, socket}
  end

  # Disconnected mount carries it on socket.private; connected mount carries it
  # on the pruned conn that LiveViewTest threads in as connect_info.
  defp arena_config(socket) do
    Map.get(socket.private, :arena_config) || from_connect_info(socket)
  end

  defp from_connect_info(%{private: %{connect_info: %{private: %{arena_config: %Arena.Config{} = c}}}}),
    do: c

  defp from_connect_info(_), do: nil
end
```

Wire it as a global hook in your `MyAppWeb, :live_view` macro
(`on_mount MyAppWeb.LiveArena`). It runs **before** `mount/3`, so the view's own
subscriptions and `via_tuple()` calls resolve to the per-test owner. In dev/prod
no config is ever injected, so it's a no-op.

> **Belt-and-suspenders:** because the connected process also has `[test_pid]` in
> `$callers`, you can resolve the config without the on_mount hook by walking
> `$callers` and reading the test process's `:arena_config` (see §5). The on_mount
> hook is cleaner; the `$callers` read is a robust fallback for any other process
> Phoenix spawns for you.

Prove it once, so a future refactor can't silently break it:

```elixir
test "the connected LiveView carries this test's Arena config", %{conn: conn, config: config} do
  {:ok, view, _html} = live(conn, "/dashboard")
  assert Arena.Debug.arena_config(view.pid) == config   # your inspector
end
```

### 3c. Channels — the same idea, threaded through `connect/3`

A channel join runs in its own process. Thread the config through `connect_info`
into the socket, then store it at the top of `join/3`:

```elixir
# UserSocket.connect/3 — nil in prod (real connect_info never carries this key)
|> assign(:arena_config, connect_info[:arena_config])

# Channel.join/3 — first thing
def join(_topic, _params, socket) do
  store_arena_config(socket)   # Arena.Config.store + execute_callbacks (Ecto allow)
  ...
end
```

And in the test: `connect(UserSocket, params, connect_info: %{arena_config: config})`.
Run `Arena.Config.execute_callbacks/1` when you store, so the channel process is
authorized onto the sandbox connection (the channel equivalent of what
`Arena.Process`'s `init` wrapper does for a wrapped GenServer).

## 4. Isolating `Phoenix.PubSub` per test — the all-or-nothing rule

`Arena.Integrations.PubSub.setup/2` starts a per-test PubSub server and stores its
name at `:pubsub_name`. That server only isolates if **every** broadcaster and
subscriber in the test resolves the **same** name. Route everything through a thin
facade instead of the literal global server name:

```elixir
defmodule MyApp.PubSub do
  # doubles as the prod server name: {Phoenix.PubSub, name: MyApp.PubSub}
  def server, do: Map.get(Arena.Config.current().context, :pubsub_name) || from_callers() || __MODULE__
  def broadcast(topic, msg), do: Phoenix.PubSub.broadcast(server(), topic, msg)
  def subscribe(topic), do: Phoenix.PubSub.subscribe(server(), topic)
  # … broadcast!/local_broadcast/unsubscribe

  defp from_callers do
    Enum.find_value(Process.get(:"$callers", []), fn pid ->
      with {:dictionary, d} <- Process.info(pid, :dictionary),
           %Arena.Config{context: %{pubsub_name: n}} <- Keyword.get(d, :arena_config),
           do: n, else: (_ -> nil)
    end)
  end
end
```

Then replace `Phoenix.PubSub.broadcast(MyApp.PubSub, …)` with
`MyApp.PubSub.broadcast(…)` **everywhere — lib and tests**. In prod no config is
stored, so `server/0` is always `MyApp.PubSub`.

The resolution order — current process's config → `$callers` ancestor's config →
global — means it Just Works for: the test process (has config), Arena-wrapped
GenServers/Tasks (carry it via `wrap`), the connected LiveView (on_mount stores
it; also in `$callers`), and a bare `Task` spawned in a test (test pid in
`$callers`).

## 5. Debugging silently-lost PubSub messages

The classic symptom: a LiveView PubSub test asserts the UI updated, but it didn't,
and there's no error. The message went to a different server than the subscriber
listened on. To find which side is wrong, **instrument the resolver** temporarily:

```elixir
def broadcast(topic, msg) do
  s = server()
  IO.puts(:stderr, "PUBSUB broadcast self=#{inspect(self())} server=#{inspect(s)} topic=#{topic}")
  Phoenix.PubSub.broadcast(s, topic, msg)
end
# … same in subscribe/2
```

Run the failing test and compare the `server=` on the subscribe line vs the
broadcast line. In practice the two failure modes are:

1. **A missed call site** still uses the literal global name (`Phoenix.PubSub.broadcast(MyApp.PubSub, …)`).
   Easy to miss **multi-line** calls when doing a mechanical replace — e.g.
   `Phoenix.PubSub.broadcast(\n  MyApp.PubSub,\n  topic,\n  msg\n)` — a same-line
   regex skips them. Grep with a newline-tolerant pattern.
2. **An unwrapped broadcaster** (an Oban job, a bare process) has no config and is
   not in `$callers`, so it resolves the global server. Arena-wrap it
   (`Arena.Task` / `use Arena.Process`) so it carries the config.

## 6. The real boundary: Wallaby / Playwright

Browser-driven tests DO cross a real transport, so neither `$callers` nor the
in-process `connect_info` trick applies. Use the canonical
`Phoenix.Ecto.SQL.Sandbox` metadata route: encode the owner into the `User-Agent`
header (`Phoenix.Ecto.SQL.Sandbox.metadata_for/2`), declare
`connect_info: [:user_agent, …]` on the socket, and `allow/2` in an `on_mount`.
The same channel can carry an Arena owner/pubsub name if you need server-level
isolation in browser tests — but most browser suites accept the shared
infrastructure and run `async: false`.

## Checklist

- [ ] Case template builds the config and stashes it on `conn.private[:arena_config]`.
- [ ] A global `on_mount` hook stores it in the connected LiveView (and a channel
      `join/3` equivalent), running `execute_callbacks/1` for Ecto allow.
- [ ] One test asserts the connected `view.pid` carries the exact per-test config.
- [ ] All PubSub broadcast/subscribe calls — lib **and** tests — go through a
      facade that resolves the server from `Arena.Config` (with a `$callers`
      fallback). No literal global server name outside the facade and the
      `{Phoenix.PubSub, name: …}` startup.
- [ ] Wallaby/Playwright suites use the `Phoenix.Ecto.SQL.Sandbox` user-agent
      metadata pattern and `async: false`.
