defmodule Arena.Case do
  @moduledoc """
  Helpers for an ExUnit case template that gives every test per-test Arena
  isolation, so you don't hand-write (and mis-order) the setup pipeline.

  Wire it into a tiny `DataCase`:

      defmodule MyApp.DataCase do
        use ExUnit.CaseTemplate

        using do
          quote do
            import Arena.Case, only: [wrap!: 1, wrap!: 2]
          end
        end

        setup tags do
          Arena.Case.setup_isolation(tags, repo: MyApp.Repo, pubsub: true)
        end
      end

      defmodule MyApp.WorkerTest do
        use MyApp.DataCase, async: true

        test "isolated", %{config: config} do
          {:ok, _pid} = start_supervised!({MyApp.Worker, wrap!(config, args)})
        end
      end

  `setup_isolation/2` builds the per-test `Arena.Config`, checks out the Ecto
  sandbox (when `:repo` is given), starts a per-test PubSub server (when
  `pubsub: true`), stores the config **before any spawn** (the load-bearing
  ordering), and fails loudly if isolation ever collapses onto the shared
  `:arena_global` owner. It returns `{:ok, context}` exposing:

    * `:config` / `:arena` — the per-test `Arena.Config`
    * `:pubsub` — the per-test PubSub server name (only when `pubsub: true`)

  `wrap!/2` is `Arena.wrap/2` with a loud guard against the `:arena_global`
  owner — use it instead of `Arena.wrap/2` to turn a silent crosstalk fallback
  (a store that never ran, or ran after the spawn) into a clear failure.
  """

  alias Arena.Config

  @doc """
  Builds per-test Arena isolation from the ExUnit `tags`. See the moduledoc for
  options and the returned context.

  ## Options

    * `:repo` — an Ecto repo. Checks out a sandbox connection (`shared:` is
      derived from `tags[:async]`) and adds `Arena.Integrations.Ecto`. Requires
      `:ecto_sql`.
    * `:pubsub` — when `true`, adds `Arena.Integrations.PubSub` (a per-test
      `Phoenix.PubSub` server, exposed as `:pubsub`). Requires `:phoenix_pubsub`.
  """
  @spec setup_isolation(map(), keyword()) :: {:ok, keyword()}
  def setup_isolation(tags, opts \\ []) do
    config =
      tags
      |> Arena.setup()
      |> maybe_ecto(tags, opts[:repo])
      |> maybe_pubsub(opts[:pubsub])
      |> Config.store()

    if config.owner == :arena_global do
      raise """
      Arena.Case isolation collapsed onto the shared :arena_global owner.
      Arena.Config.store/1 did not assign a per-test owner — every Arena-wrapped
      process in this test would cross-talk. Refusing to run.
      """
    end

    {:ok, context(config, opts)}
  end

  @doc """
  `Arena.wrap/2` with a loud guard: raises if `config.owner` is `:arena_global`
  (the silent fallback that means the store never ran, or ran after the spawn).
  """
  @spec wrap!(Config.t(), any()) :: Arena.Wrapped.t()
  def wrap!(config, input \\ nil)

  def wrap!(%Config{owner: :arena_global}, _input) do
    raise """
    Refusing to Arena.wrap/2 under the shared :arena_global owner. This means
    Arena.Config.store/1 was never called for this test (or was called after the
    process spawned). Pass the per-test `config` from your DataCase setup and
    ensure store completes before any spawn.
    """
  end

  def wrap!(%Config{} = config, input), do: Arena.wrap(config, input)

  defp maybe_ecto(config, _tags, nil), do: config

  defp maybe_ecto(config, tags, repo) do
    unless Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      raise RuntimeError, "Arena.Case `:repo` requires `:ecto_sql` in your deps."
    end

    pid = apply(Ecto.Adapters.SQL.Sandbox, :start_owner!, [repo, [shared: not tags[:async]]])
    ExUnit.Callbacks.on_exit(fn -> apply(Ecto.Adapters.SQL.Sandbox, :stop_owner, [pid]) end)
    Arena.Integrations.Ecto.setup(config, repo: repo)
  end

  defp maybe_pubsub(config, true), do: Arena.Integrations.PubSub.setup(config)
  defp maybe_pubsub(config, _), do: config

  defp context(config, opts) do
    base = [arena: config, config: config]

    if opts[:pubsub] do
      Keyword.put(base, :pubsub, Config.get(config, :pubsub_name))
    else
      base
    end
  end
end
