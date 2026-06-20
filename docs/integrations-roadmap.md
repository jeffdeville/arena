# Integrations & roadmap

Arena's value compounds when the infrastructure your test spawns is isolated for
you. An "integration" is a small, composable function that adds a callback (or a
piece of context) to an `Arena.Config`, executed when each wrapped process
starts. This is the map of what ships today and what's still on the table.

## Shipping

| Integration | What it does | Optional dep |
|---|---|---|
| `Arena.Integrations.Ecto` | `setup(config, repo: Repo)` adds the `Sandbox.allow/3` callback so each wrapped child shares the test's checked-out connection. | `:ecto_sql` |
| `Arena.Integrations.PubSub` | `setup(config, opts)` starts a per-test `Phoenix.PubSub` server and stores its name at `:pubsub_name`. | `:phoenix_pubsub` |
| `Arena.Integrations.Mox` | `setup(config, mocks: […])` adds a `Mox.allow/3` callback so Mox `:private`-mode mocks work from Arena-spawned processes at `async: true`. | `:mox` |
| `Arena.Integrations.Telemetry` | `capture(events, to: pid)` attaches an owner-scoped `:telemetry` handler that forwards events to the test process and detaches on exit. | `:telemetry` |
| `Arena.Phoenix` | LiveView `on_mount` / Channel `join` / ConnCase seams + a PubSub server resolver, so per-test config reaches the connected LiveView/Channel process. Dependency-free. | (`:phoenix_pubsub` only for the facade's broadcasts) |
| `Arena.Credo.Check.*` | Four Credo checks enforcing correct Arena usage (must `use Arena.Process`; no test `Process.sleep`; no global Mox; no `Application.put_env` in tests). Compiled only when Credo is present. | `:credo` |
| `Arena.Case` | A setup helper (`setup_isolation/2` + `wrap!/2`) that owns the load-bearing DataCase pipeline + the `:arena_global` tripwire. | — |
| `ArenaApplication` | Async-safe `Application.get_env/3` drop-in: per-test override from `Arena.Config` (`{app, key}`-namespaced) → app env. Also `put_env/3,4` and surgical `merge_env/3,4`. | — |

All optional deps are guarded with `Code.ensure_loaded?/1` (runtime) or
`if Code.ensure_loaded?` (compile-time, for the Credo checks), so Arena's core
stays dependency-free and a consumer only needs the dep for the integration they
actually use. The shape every callback-based integration follows (model new ones
on `Arena.Integrations.Ecto`):

```elixir
def setup(%Arena.Config{} = config, opts) do
  unless Code.ensure_loaded?(SomeDep), do: raise(helpful_error())
  Arena.Config.add_callback(config, {__MODULE__, :on_child_start, [opts]})
end

@doc false
def on_child_start(_config, opts), do: # runs in each wrapped process at init
```

## Documentation

- [testing-phoenix.md](testing-phoenix.md) — testing LiveView & Channels (the
  connected-process recipe `Arena.Phoenix` implements).
- [http-boundary.md](http-boundary.md) — where Arena can't reach, and what to do
  (swap the client + Mox; `Req.Test`/`Bypass`; the browser-test sandbox metadata).

## Still on the table

- **`Arena.Integrations.Oban`** — per-test isolation for Oban jobs: run a job
  inline **wrapped** with the test config (so its DB + PubSub resolve per-test),
  and/or a callback to `allow` Oban's peer/notifier processes. Layered on
  `Oban.Testing` rather than replacing it. (Deferred — Oban already has strong
  test tooling; this is opportunistic.)

## Open question

Everything ships **inside `arena`** behind optional deps for now (no sibling
packages). If the Credo dependency ever proves awkward for a consumer's release
tooling, the checks are the natural candidate to split into an `arena_credo`
package later — but the `Code.ensure_loaded?` compile guard keeps them
prod-safe today.
