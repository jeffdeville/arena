defmodule ArenaApplication do
  @moduledoc """
  An Arena-aware, async-safe drop-in for `Application.get_env/3`.

  ## Why

  Code frequently reads a swappable collaborator or tunable from the application
  environment — `Application.get_env(:my_app, :http_client, MyApp.HTTP.Real)`. To
  swap it in a test (a mock module, a shrunk backoff, a feature toggle) the
  classic move is `Application.put_env/3` in `setup` with an `on_exit/1` to
  restore it. That mutates **global** node state, so:

    * any suite that does it must run `async: false`, and
    * two suites that want *different* values for the same `{app, key}` cannot run
      concurrently without clobbering each other.

  `ArenaApplication.get_env/3` reads a per-test override from the **current
  `Arena.Config`** first, falling back to `Application.get_env/3` when none is
  set. A test stores its override in its OWN process's config — and `Arena.wrap/2`
  carries that config into Arena-wrapped consumers (`Arena.Process` GenServers,
  `Arena.Task`s) — so the swap is process-local and suites stay `async: true`.

  In production no `Arena.Config` is ever stored, so `Config.current/0` returns
  the empty default and `get_env/3` is **exactly** `Application.get_env/3` —
  introducing this seam is behaviour-neutral.

  ## Usage

      # Library / production read — swap this:
      #   Application.get_env(:my_app, :http_client, MyApp.HTTP.Real)
      # for this:
      ArenaApplication.get_env(:my_app, :http_client, MyApp.HTTP.Real)

      # Test (process-local, async-safe — replaces Application.put_env/3).
      # `config` is the per-test Arena.Config from your DataCase setup:
      setup %{config: config} do
        config = ArenaApplication.put_env(config, :my_app, :http_client, MyApp.HTTP.Mock)
        Arena.Config.store(config)
        :ok
      end

  ## Overrides are namespaced by `{app, key}`

  Unlike a bare context key, an override is keyed by **both** the app and the key,
  exactly like `Application`'s own `{app, key}` namespace — so two apps may use the
  same `key` without colliding, and the override resolution mirrors what the
  production `Application.get_env/3` fallback would see.
  """

  alias Arena.Config

  @doc """
  Like `Application.get_env/3`, but prefers a per-test `Arena.Config` override for
  `{app, key}`. Falls back to `Application.get_env(app, key, default)`.
  """
  @spec get_env(atom(), atom(), term()) :: term()
  def get_env(app, key, default \\ nil) when is_atom(app) and is_atom(key) do
    case fetch_override(app, key) do
      {:ok, value} -> value
      :error -> Application.get_env(app, key, default)
    end
  end

  @doc """
  Like `Application.fetch_env/2`, but prefers a per-test `Arena.Config` override
  for `{app, key}`. Falls back to `Application.fetch_env(app, key)`.
  """
  @spec fetch_env(atom(), atom()) :: {:ok, term()} | :error
  def fetch_env(app, key) when is_atom(app) and is_atom(key) do
    case fetch_override(app, key) do
      {:ok, value} -> {:ok, value}
      :error -> Application.fetch_env(app, key)
    end
  end

  @doc """
  Like `Application.fetch_env!/2`, but prefers a per-test `Arena.Config` override
  for `{app, key}`. Falls back to `Application.fetch_env!(app, key)` (which raises
  if the key is also unset in the application environment).
  """
  @spec fetch_env!(atom(), atom()) :: term()
  def fetch_env!(app, key) when is_atom(app) and is_atom(key) do
    case fetch_override(app, key) do
      {:ok, value} -> value
      :error -> Application.fetch_env!(app, key)
    end
  end

  @doc """
  Puts a per-test override for `{app, key}` into `config`, returning the updated
  config. Pipeable like `Arena.Config.put/3`; does NOT itself call
  `Arena.Config.store/1`, so the caller controls when the config is stored
  (and `Arena.wrap/2`-ped into child processes).

      config
      |> ArenaApplication.put_env(:my_app, :http_client, MyApp.HTTP.Mock)
      |> Arena.Config.store()
  """
  @spec put_env(Config.t(), atom(), atom(), term()) :: Config.t()
  def put_env(%Config{} = config, app, key, value) when is_atom(app) and is_atom(key) do
    Config.put(config, namespace(app, key), value)
  end

  @doc """
  Puts a per-test override for `{app, key}` into the CURRENT process's
  `Arena.Config` (read via `Arena.Config.current/0`, stored back via
  `Arena.Config.store/1`), mirroring the side-effecting shape of
  `Application.put_env/3`. Returns the updated config.
  """
  @spec put_env(atom(), atom(), term()) :: Config.t()
  def put_env(app, key, value) when is_atom(app) and is_atom(key) do
    Config.current()
    |> Config.put(namespace(app, key), value)
    |> Config.store()
  end

  @doc """
  Surgically merges `changes` into the existing value for `{app, key}`, rather
  than replacing it.

  Where `put_env/3` *replaces* the whole value, `merge_env/3` reads the current
  **effective** value (the override if one is set, else `Application.get_env/2`,
  else `%{}`) and shallow-merges `changes` (a map or keyword list) into it,
  storing the result as the override in the current process's config. So a test
  states only the delta:

      # only google_calendar is swapped; none/jobber keep their resolved values
      ArenaApplication.merge_env(:my_app, :provider_impls,
        google_calendar: MyApp.ProviderMock
      )

  This keeps the test's intent legible and avoids restating (and accidentally
  desyncing) the rest of a large map. The merge is **shallow** and the result
  takes the base's shape: a map base stays a map, a keyword base stays a keyword
  list. Merging into a non-collection value raises.

  > #### Resolvable base required {: .info}
  > The merge starts from the *effective* value, so for the unchanged keys to
  > survive, the production default must be resolvable — i.e. live in the
  > application environment (`config :my_app, :provider_impls, %{…}`), or be
  > established by an earlier `put_env`/`merge_env`. A hard-coded literal default
  > buried in the reader function is invisible here.
  """
  @spec merge_env(atom(), atom(), Enumerable.t()) :: Config.t()
  def merge_env(app, key, changes) when is_atom(app) and is_atom(key) do
    Config.current()
    |> merge_env(app, key, changes)
    |> Config.store()
  end

  @doc """
  Pipeable form of `merge_env/3`: merges `changes` into `config`'s value for
  `{app, key}` and returns the updated config (does NOT call
  `Arena.Config.store/1`).

      config
      |> ArenaApplication.merge_env(:my_app, :provider_impls, google_calendar: Mock)
      |> Arena.Config.store()
  """
  @spec merge_env(Config.t(), atom(), atom(), Enumerable.t()) :: Config.t()
  def merge_env(%Config{} = config, app, key, changes) when is_atom(app) and is_atom(key) do
    merged = merge_value(effective_value(config, app, key), changes)
    put_env(config, app, key, merged)
  end

  # We read `context` directly (not `Config.get/2`) because `get/2` is
  # `Map.fetch!`-backed and RAISES on an absent key — and "absent" is exactly the
  # production / non-injecting-test path that must fall through to Application.
  # `Map.fetch/2` (not `Map.get/2`) so a deliberate override TO `nil` is honoured.
  defp fetch_override(app, key) do
    Map.fetch(Config.current().context, namespace(app, key))
  end

  # The current effective value for `{app, key}` resolved against an explicit
  # config: the override stored in this config, else the application env, else nil.
  defp effective_value(%Config{context: context}, app, key) do
    case Map.fetch(context, namespace(app, key)) do
      {:ok, value} -> value
      :error -> Application.get_env(app, key)
    end
  end

  # Shallow-merge `changes` into `base`, preserving the base's shape.
  defp merge_value(base, changes) when is_map(base), do: Map.merge(base, Map.new(changes))

  defp merge_value(base, changes) when is_list(base),
    do: Keyword.merge(base, Enum.to_list(changes))

  defp merge_value(nil, changes), do: Map.new(changes)

  defp merge_value(base, _changes) do
    raise ArgumentError,
          "ArenaApplication.merge_env/3 can only merge into a map or keyword list, " <>
            "got: #{inspect(base)}. Use put_env/3 to replace a scalar value."
  end

  # Namespace overrides under this module + the `{app, key}` pair so they never
  # collide with Arena's own context keys (`:pubsub`, integration callbacks, …)
  # or with arbitrary user context, while still keying on the app like
  # `Application` does.
  defp namespace(app, key), do: {__MODULE__, app, key}
end
