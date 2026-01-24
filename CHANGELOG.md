# Changelog

All notable changes to Arena will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
