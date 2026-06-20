# Start the Registry for Arena tests
{:ok, _} = Registry.start_link(keys: :unique, name: :arena_registry)

# Credo is a `runtime: false` optional dep, so its service processes aren't
# auto-started. The Arena.Credo.Check tests use `Credo.Test.Case`, which needs
# those services, so start them here (no-op if Credo isn't available).
if Code.ensure_loaded?(Credo.Application), do: Application.ensure_all_started(:credo)

ExUnit.start()
