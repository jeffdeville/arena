# Start the Registry for Arena tests
{:ok, _} = Registry.start_link(keys: :unique, name: :arena_registry)

ExUnit.start()
