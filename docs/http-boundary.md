# The HTTP boundary

Arena threads its per-test config through the **process dictionary**. That works
across every process whose lineage Arena (or the test) controls — wrapped
GenServers/Tasks, and the in-process Phoenix test helpers. It fundamentally
cannot reach a process that doesn't inherit that dictionary:

- a **real** Bandit/Cowboy worker handling a production request,
- a **browser** WebSocket in Wallaby/Playwright,
- an **outbound HTTP call** to a third party.

This is an essential limitation, not a bug. The strategy is to **not cross the
boundary in the first place** where you can, and to use an explicit ownership
mechanism where you must.

> Note: `Phoenix.ConnTest`, `Phoenix.LiveViewTest`, and `Phoenix.ChannelTest` run
> **in-process** — they are NOT this boundary, and they isolate cleanly with
> Arena at `async: true`. See [testing-phoenix.md](testing-phoenix.md).

## Pattern 1 (preferred): swap the client, don't make the call

Read your HTTP/third-party client as a swappable value and inject a mock per
test. Then your code never makes a real request — the boundary is a behaviour
contract you own, mocked in-process with Mox.

```elixir
# production — the client is resolved, not hard-coded:
def fetch(url), do: client().get(url)
defp client, do: ArenaApplication.get_env(:my_app, :http_client, MyApp.HTTP.Finch)

# test — inject the mock (process-local, async-safe) and set an expectation:
setup %{config: config} do
  ArenaApplication.put_env(config, :my_app, :http_client, MyApp.HTTPMock)
  Arena.Config.store(config)
  :ok
end

test "..." do
  Mox.expect(MyApp.HTTPMock, :get, fn _url -> {:ok, %{status: 200}} end)
  # ... and if the call happens inside an Arena-wrapped process, add
  #     Arena.Integrations.Mox so :private mode reaches it.
end
```

This keeps everything in-process: no real socket, full `async: true`,
`Arena.Integrations.Mox` carries the expectation into wrapped processes. **This is
the right default** — most "HTTP boundary" problems are really "I hard-coded the
client" problems.

## Pattern 2: a real outbound call you can't avoid

When the request itself is under test (you're testing the client/adapter, not the
caller), use a tool whose ownership is caller/`$callers`-aware so it survives
Arena's process tree:

- [`Req.Test`](https://hexdocs.pm/req/Req.Test.html) — Req's built-in stub plug;
  ownership follows the process tree (and you can `Req.Test.allow/3` for spawned
  processes, exactly like the Ecto sandbox).
- [`Bypass`](https://hexdocs.pm/bypass) — a real local HTTP server; the test owns
  it and points the client at `http://localhost:#{bypass.port}`.

Both keep you in-VM (no browser), so async is usually fine; allow the consuming
process if it's one Arena spawned.

## Pattern 3: the real transport (Wallaby / Playwright)

Browser-driven tests cross a genuine WebSocket/HTTP boundary, so neither the
process dictionary nor `$callers` reaches the server processes. Use the canonical
`Phoenix.Ecto.SQL.Sandbox` metadata route — encode the sandbox owner into the
`User-Agent` header (`Phoenix.Ecto.SQL.Sandbox.metadata_for/2`), declare
`connect_info: [:user_agent, …]` on the socket, and `allow/2` in an `on_mount` —
and run `async: false`. The same channel can carry an Arena owner/pubsub name if
you need server-level isolation in browser tests, but most browser suites accept
shared infrastructure.

## Rule of thumb

| Situation | Approach | async? |
|---|---|---|
| Caller of an HTTP client | Pattern 1 — swap the client, mock the behaviour | ✅ |
| The client/adapter itself | Pattern 2 — `Req.Test` / `Bypass` (allow spawned procs) | usually ✅ |
| Browser end-to-end | Pattern 3 — sandbox user-agent metadata | ❌ |
