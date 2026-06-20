defmodule Arena.Phoenix.PubSub do
  @moduledoc """
  Resolve which `Phoenix.PubSub` server to use per process, so async tests get a
  genuinely isolated server (started by `Arena.Integrations.PubSub`) instead of
  just topic-scoped traffic on the shared one.

  ## The all-or-nothing rule

  A per-test PubSub server only isolates if **every** broadcaster and subscriber
  in the test resolves the **same** server. Route all of them through a facade
  that resolves the server from `Arena.Config` — `use Arena.Phoenix.PubSub` to
  generate one named after your production server:

      defmodule MyApp.PubSub do
        # `MyApp.PubSub` is both the prod server name (`{Phoenix.PubSub, name:
        # MyApp.PubSub}`) and this facade module.
        use Arena.Phoenix.PubSub
      end

  This generates `server/0`, `broadcast/2`, `broadcast!/2`, `local_broadcast/2`,
  `subscribe/1`, and `unsubscribe/1`. Then call `MyApp.PubSub.broadcast(topic, msg)`
  instead of `Phoenix.PubSub.broadcast(MyApp.PubSub, topic, msg)` **everywhere —
  lib and tests**. In production no per-test server is injected, so `server/0` is
  always your global server.

  Pass `:server` to override the default (the using module):

      use Arena.Phoenix.PubSub, server: MyApp.InternalPubSub

  ## Resolution order

  `server/1` returns, in order:

    1. the `:pubsub_name` stored in the CURRENT process's `Arena.Config` (set by
       `Arena.Integrations.PubSub.setup/2`, carried to wrapped processes via
       `Arena.wrap`, and to a connected LiveView via `Arena.Phoenix.LiveView`);
    2. else the per-test server of the first `$callers` ancestor that carries one
       — `Phoenix.LiveViewTest`/`Task` put the test pid in `$callers`, so a bare
       `Task` spawned in a test still resolves (the same channel the Ecto sandbox
       and Mox use);
    3. else the `default` (your global server).
  """

  alias Arena.Config

  @doc """
  Resolves the PubSub server for the current process (see the moduledoc for the
  order), falling back to `default`.
  """
  @spec server(atom()) :: atom()
  def server(default) do
    case Map.get(Config.current().context, :pubsub_name) do
      nil -> from_callers() || default
      name -> name
    end
  end

  defp from_callers do
    Enum.find_value(Process.get(:"$callers", []), fn pid ->
      with {:dictionary, dict} <- Process.info(pid, :dictionary),
           %Config{context: %{pubsub_name: name}} <- Keyword.get(dict, :arena_config) do
        name
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Generates a per-app PubSub facade. See the moduledoc.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [server_opt: Keyword.get(opts, :server)] do
      @arena_pubsub_server server_opt || __MODULE__

      @doc "The resolved PubSub server for the current process."
      def server, do: Arena.Phoenix.PubSub.server(@arena_pubsub_server)

      def broadcast(topic, message), do: Phoenix.PubSub.broadcast(server(), topic, message)
      def broadcast!(topic, message), do: Phoenix.PubSub.broadcast!(server(), topic, message)

      def local_broadcast(topic, message),
        do: Phoenix.PubSub.local_broadcast(server(), topic, message)

      def subscribe(topic), do: Phoenix.PubSub.subscribe(server(), topic)
      def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(server(), topic)

      defoverridable server: 0
    end
  end
end
