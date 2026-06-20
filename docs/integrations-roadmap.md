# Integrations & roadmap

Arena's value compounds when the infrastructure your test spawns is isolated for
you. An "integration" is a small, composable function that adds a callback (or a
piece of context) to an `Arena.Config`, executed when each wrapped process
starts. This doc lists what ships today and concrete candidates for what's next.

## Shipping today

| Integration | What it does |
|---|---|
| `Arena.Integrations.Ecto` | `setup(config, repo: Repo)` adds the `Sandbox.allow/3` callback so each wrapped child shares the test's checked-out connection. |
| `Arena.Integrations.PubSub` | `setup(config, opts)` starts a per-test `Phoenix.PubSub` server and stores its name at `:pubsub_name`. |
| `ArenaApplication` | Async-safe `Application.get_env/3` drop-in: per-test override from `Arena.Config` (`{app, key}`-namespaced) → app env. Also `put_env/3,4` and surgical `merge_env/3,4`. Replaces `Application.put_env`-in-test. |

The shape every integration follows (model new ones on `Arena.Integrations.Ecto`):

```elixir
def setup(%Arena.Config{} = config, opts) do
  # validate deps are loaded; raise a helpful error if not
  Arena.Config.add_callback(config, {__MODULE__, :on_child_start, [opts]})
end

@doc false
def on_child_start(_config, opts), do: # runs in each wrapped process at init
```

---

## Proposed integrations

Ranked by value × how cleanly they fit Arena's model. The top three are the ones
adopters keep re-implementing by hand.

### 1. `Arena.Integrations.Mox` — carry Mox ownership into wrapped processes ⭐⭐⭐

**Problem.** Mox `:private` mode owns expectations/stubs by the **defining
process** (it walks `$callers`). An Arena-wrapped GenServer/Task spawned out of
that caller chain can't see them, so a mid-test call into a mocked behaviour gets
`Mox.UnexpectedCallError`. Teams work around it with global mode (`set_mox_global`,
which forces `async: false`) or by hand-threading `Mox.allow/3`.

**Fit.** Identical shape to `Arena.Integrations.Ecto`: add a callback that runs
`Mox.allow(mock, owner_pid, self())` in each wrapped child. This lets `:private`
mode work across the Arena process tree at `async: true`.

```elixir
config
|> Arena.Integrations.Ecto.setup(repo: Repo)
|> Arena.Integrations.Mox.setup(mocks: [MyApp.HTTPMock, MyApp.ClockMock])
```

**Notes.** Optional dep on `:mox` (guard with `Code.ensure_loaded?/1` like the
Ecto integration guards `Ecto.Adapters.SQL.Sandbox`). Pairs naturally with
`ArenaApplication`/`Application.get_env` for selecting the mock impl. **Effort: S.**

### 2. `Arena.Phoenix` — LiveView/Channel/Conn seams ⭐⭐⭐

**Problem.** Every Phoenix project re-derives how to get the per-test config into
a connected LiveView/Channel process (see [testing-phoenix.md](testing-phoenix.md)).
It's subtle (two mounts, `$callers`, `connect_info` as the pruned conn) and easy
to get wrong in a way that silently loses PubSub messages.

**Fit.** Ship the proven seam as a tiny, optional Phoenix add-on:

```elixir
# A global on_mount hook (no-op in prod):
on_mount Arena.Phoenix.LiveView            # stores config from connect_info/socket.private

# A ConnCase helper:
conn = Arena.Phoenix.put_config(conn, config)   # stash on conn.private[:arena_config]

# A channel join helper:
Arena.Phoenix.store_from_socket(socket)    # store + execute_callbacks in the join process

# A PubSub server resolver (the facade core):
Arena.Phoenix.PubSub.server(default)       # config :pubsub_name → $callers → default
```

**Notes.** Could live in this repo behind an optional `:phoenix_live_view` dep, or
in a sibling `arena_phoenix` package to keep core dependency-free. The `$callers`
fallback in the resolver is what makes it robust for processes Phoenix spawns for
you. **Effort: M.**

### 3. Arena Credo checks — enforce correct usage ⭐⭐⭐

**Problem.** Arena's guarantees rely on conventions a reviewer can't reliably
catch: every stateful GenServer must `use Arena.Process`; tests must not
`Process.sleep` for synchronization, must not use global Mox, must not
`Application.put_env` (use `ArenaApplication`). These regress silently.

**Fit.** Ship a set of `Credo.Check`s so projects can fail CI on regressions:

- `Arena.Credo.Check.GenServerUsesArenaProcess` — a `lib/` module that
  `use GenServer` must also `use Arena.Process` (with an `:exempt_modules` param).
- `Arena.Credo.Check.NoTestProcessSleep` — `Process.sleep` in `test/` (allow with
  a justification comment / `:allowed_paths`).
- `Arena.Credo.Check.NoGlobalMox` — `set_mox_global` / `Mox` global mode in tests.
- `Arena.Credo.Check.NoApplicationPutEnvInTest` — `Application.put_env` in tests
  (steer to `ArenaApplication`).

**Notes.** Best as a separate `arena_credo` hex package (Credo is a dev/test-only
dep and authoring `Credo.Check`s pulls Credo in). A reference implementation of
all four exists in the wild and can be upstreamed. **Effort: M.**

### 4. `Arena.Case` — a base ExUnit case template ⭐⭐

**Problem.** Every adopter writes the same `DataCase` setup: `start_owner!` →
`Arena.setup |> Integrations.Ecto.setup |> Integrations.PubSub.setup |> store`,
plus the `:arena_global` collapse tripwire and a guarded `wrap!` that fails loudly
instead of silently wrapping under the shared owner.

**Fit.** A `use Arena.Case, repo: MyApp.Repo` (or a `__using__` mixin) that
generates that setup and exposes `config`/`arena` context + `wrap!/2`. Keeps the
load-bearing ordering (store before spawn) correct by construction.

```elixir
defmodule MyApp.DataCase do
  use Arena.Case, repo: MyApp.Repo, pubsub: true
end
```

**Effort: S–M.**

### 5. `Arena.Integrations.Oban` — per-test job isolation ⭐⭐

**Problem.** Oban workers run in their own processes; in tests they neither carry
the config nor (for `Oban.Testing.perform_job/3` run inline) reliably share the
sandbox unless allowed. Broadcasts from a job land on the global PubSub.

**Fit.** A helper to run a job inline **wrapped** with the test config (so its DB
+ PubSub resolve per-test), and/or a callback to `allow` Oban's peer/notifier
processes. Likely layered on `Oban.Testing` rather than replacing it.

**Notes.** Oban already has strong testing tooling; this is about making Arena's
per-test infra visible to inline jobs. **Effort: M.**

### 6. HTTP-boundary helpers (documentation-first) ⭐

**Problem.** The HTTP boundary is where Arena fundamentally can't reach. Today the
guidance is "`Application.put_env` + `async: false`" or "use the sandbox
user-agent metadata."

**Fit.** Mostly a documented pattern, optionally a thin helper around `Req.Test`
/ `Bypass` ownership + `ArenaApplication` for swapping the client per test. Worth a
dedicated `docs/http-boundary.md` more than a code module. **Effort: S (docs).**

### 7. `Arena.Integrations.Telemetry` — per-test handler capture ⭐

**Problem.** `:telemetry` handlers are global (keyed by handler id), so a test that
attaches a capture handler can collide with a concurrent test on the same event.

**Fit.** Attach a per-test handler whose id includes the Arena owner, forwarding
matched events to the test pid, detached on exit. Niche but clean. **Effort: S.**

---

## Recommendation

Do **(1) Mox**, **(2) Phoenix**, and **(3) Credo checks** first — they're the
integrations adopters re-implement by hand, and (1) and (2) are the direct
follow-on to the LiveView/PubSub work that produced this doc. **(4) Arena.Case**
is a small ergonomics win worth bundling. **(5)–(7)** are opportunistic.

Open question for each: ship inside `arena` behind an optional dependency, or as a
sibling package (`arena_phoenix`, `arena_credo`) to keep the core dependency-free?
The integrations that need a heavy/dev-only dep (Credo) lean toward a sibling
package; the lightweight ones (Mox, Telemetry) can live in core, guarded by
`Code.ensure_loaded?/1` exactly as the Ecto integration already is.
