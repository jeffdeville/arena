defmodule Arena.Integrations.Mox do
  @moduledoc """
  Integration with [Mox](https://hexdocs.pm/mox) for using `:private`-mode mocks
  across the Arena process tree.

  Mox's `:private` mode owns expectations and stubs by the **defining process**
  (it resolves them by walking `$callers`). A process Arena spawns —
  an `Arena.Process` GenServer or an `Arena.Task` — runs outside that caller
  chain, so a call into a mocked behaviour from inside it raises
  `Mox.UnexpectedCallError`. The usual workarounds are global mode
  (`Mox.set_mox_global/0`, which forces `async: false`) or scattering
  `Mox.allow/3` by hand.

  This integration adds the same kind of callback as `Arena.Integrations.Ecto`:
  when each wrapped process starts, it runs `Mox.allow(mock, owner_pid, self())`
  for every named mock, so `:private` mode works across the tree at `async: true`.

  ## Usage

      config =
        context
        |> Arena.setup()
        |> Arena.Integrations.Ecto.setup(repo: MyApp.Repo)
        |> Arena.Integrations.Mox.setup(mocks: [MyApp.HTTPMock, MyApp.ClockMock])
        |> Arena.Config.store()

      # in the test process, as usual:
      Mox.expect(MyApp.HTTPMock, :get, fn _url -> {:ok, %{status: 200}} end)

      # the wrapped GenServer can now call MyApp.HTTPMock.get/1 and see the expectation
      {:ok, _pid} = MyApp.Worker.start_link(Arena.wrap(config, args))

  ## Options

    * `:mocks` — (required) a list of mock modules (from `Mox.defmock/2`).
    * `:owner_pid` — (optional) the process that defined the expectations.
      Defaults to `self()` (the test process).

  Pairs naturally with `ArenaApplication`/`Application.get_env` for selecting the
  mock implementation at the call site.
  """

  alias Arena.Config

  @doc """
  Adds the Mox allowance to an Arena config. See the moduledoc for options.
  """
  @spec setup(Config.t(), keyword()) :: Config.t()
  def setup(%Config{} = config, opts) do
    unless mox_available?() do
      raise RuntimeError, """
      Mox is not available.

      To use Arena.Integrations.Mox, add Mox to your test dependencies:

          {:mox, "~> 1.0", only: :test}
      """
    end

    mocks = Keyword.fetch!(opts, :mocks)
    owner_pid = Keyword.get(opts, :owner_pid, self())

    Config.add_callback(config, {__MODULE__, :allow_mocks, [mocks: mocks, owner_pid: owner_pid]})
  end

  @doc false
  def allow_mocks(_config, opts) do
    mocks = Keyword.fetch!(opts, :mocks)
    owner_pid = Keyword.fetch!(opts, :owner_pid)

    if mox_available?() do
      Enum.each(mocks, fn mock -> apply(Mox, :allow, [mock, owner_pid, self()]) end)
    end

    :ok
  end

  defp mox_available?, do: Code.ensure_loaded?(Mox)
end
