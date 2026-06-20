# Changelog

All notable changes to Arena will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `Arena.Integrations.Mox` — `setup(config, mocks: […])` adds a `Mox.allow/3`
  callback so `:private`-mode Mox works from Arena-spawned processes at
  `async: true` (no `set_mox_global`). Guarded by `Code.ensure_loaded?(Mox)`.
- `Arena.Integrations.Telemetry` — `capture(events, to: pid)` attaches an
  owner-scoped `:telemetry` handler that forwards events to the test process and
  detaches on exit. Guarded by `Code.ensure_loaded?(:telemetry)`.
- `Arena.Phoenix` — dependency-free seams for delivering the per-test config into
  connected LiveView/Channel processes: `put_config/2` (ConnCase),
  `Arena.Phoenix.LiveView` (`on_mount`), `store_from_socket/1` (channel join),
  and `Arena.Phoenix.PubSub` (a per-test server resolver + `use` facade macro).
- `Arena.Credo.Check.*` — four Credo checks enforcing correct usage
  (`GenServerUsesArenaProcess`, `NoTestProcessSleep`, `NoGlobalMox`,
  `NoApplicationPutEnvInTest`), each compiled only when Credo is available.
- `Arena.Case` — `setup_isolation/2` + `wrap!/2`, a base-DataCase helper owning
  the setup pipeline (store-before-spawn) and the `:arena_global` tripwire.
- Docs: `llms.txt` (an agent-facing entry point following the llmstxt.org
  convention), `docs/testing-phoenix.md` (testing LiveView & Channels — the
  connected-process recipe and PubSub-isolation pitfalls),
  `docs/http-boundary.md` (where Arena can't reach), and
  `docs/integrations-roadmap.md` (the full integrations map). Wired into the hex
  package `files` and linked from the README.
- `ArenaApplication` — an async-safe drop-in for `Application.get_env/3`. Reads a
  per-test override from the current `Arena.Config` first (namespaced by
  `{app, key}`, mirroring `Application`'s own env), falling back to
  `Application.get_env/3`. Behaviour-neutral in production (no config stored), so
  it replaces the global `Application.put_env/3`-in-test pattern — and the
  `async: false` it forces — with a process-local override carried into
  Arena-wrapped consumers via `Arena.wrap/2`. Also provides `fetch_env/2`,
  `fetch_env!/2`, and `put_env/3,4`.
  - `merge_env/3,4` applies a **surgical** partial override of a map/keyword
    value: it shallow-merges a delta into the current effective value (override →
    app env), so a test states only the keys it changes instead of restating the
    whole value.
- Initial implementation of Arena process isolation system
- Core modules:
  - `Arena.Config` - Configuration blueprint for test infrastructure
  - `Arena.Wrapped` - Envelope for config + process arguments
  - `Arena.Process` - Macro for GenServer integration
  - `Arena.Supervisor` - Macro for Supervisor integration
  - `Arena.Task` - Task wrapper that preserves Arena config
- Integrations:
  - `Arena.Integrations.Ecto` - SQL Sandbox integration for database isolation
  - `Arena.Integrations.PubSub` - Phoenix.PubSub integration for isolated messaging
- Main API functions:
  - `Arena.setup/2` - Create config from test context
  - `Arena.wrap/2` - Wrap config and args into envelope
- Process helpers:
  - `via_tuple/0,1,2` - Registry-based process naming
  - `get_pid/1` - Find process by args
  - `alive?/1` - Check if process is running
  - `enable_test_kill/0` - Test cleanup macro (test env only)
- Task support:
  - `Arena.Task.async/1,2` - Spawn tasks with config
  - `Arena.Task.async_stream/3` - Parallel processing with config
  - `Arena.Task.await/2` - Wait for task results
  - `Arena.Task.await_many/2` - Wait for multiple tasks
- Config management:
  - Hierarchical process tracking via tuple IDs
  - Callback system for lazy setup
  - Context storage for arbitrary data
  - Process dictionary integration for ergonomics
- Documentation:
  - Comprehensive README with examples
  - Inline documentation for all modules and functions
  - Usage patterns and troubleshooting guide

### Changed
- N/A (initial release)

### Deprecated
- N/A (initial release)

### Removed
- N/A (initial release)

### Fixed
- N/A (initial release)

### Security
- N/A (initial release)

## [0.1.0] - 2026-01-24

### Added
- Initial release of Arena
- Clean reimplementation of Belay.Wiring with improved naming and ergonomics
- Support for async Elixir testing with process isolation
- Ecto and Phoenix.PubSub integrations
- Comprehensive test suite with 86 tests
- Full documentation

[Unreleased]: https://github.com/yourorg/arena/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yourorg/arena/releases/tag/v0.1.0
