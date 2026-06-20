if Code.ensure_loaded?(Credo.Check) do
  defmodule Arena.Credo.Check.NoApplicationPutEnvInTest do
    @moduledoc """
    Flags `Application.put_env`/`delete_env` and `System.put_env`/`delete_env` in
    tests — mutating global app/system env per test forces `async: false` and
    bleeds across tests.

    Production keeps reading `Application.get_env` (the default). The TEST should
    inject its override via dependency injection instead of mutating the global:

      * with `ArenaApplication` — read the value in production via
        `ArenaApplication.get_env(app, key, default)` and inject the per-test
        override with `ArenaApplication.put_env(config, app, key, value)`
        (process-local, async-safe), or
      * carry a behaviour value (a delay, backoff, toggle) on the `Arena.Config`
        context, or pass it as an explicit option.

    Anything that can hit a third party should be a private `Mox` mock selected
    through such an override, not a global `put_env`.

    Use `:allowed_paths` (substring match) for genuine edge-to-edge tests that
    deliberately exercise the real third party (those are `async: false` anyway),
    or annotate a one-off
    `# credo:disable-for-next-line Arena.Credo.Check.NoApplicationPutEnvInTest`
    with a reason.
    """

    use Credo.Check,
      base_priority: :high,
      category: :warning,
      param_defaults: [allowed_paths: []]

    alias Credo.SourceFile

    @forbidden %{Application: [:put_env, :delete_env], System: [:put_env, :delete_env]}

    @impl true
    def run(%SourceFile{filename: filename} = source_file, params) do
      issue_meta = IssueMeta.for(source_file, params)
      allowed = Params.get(params, :allowed_paths, __MODULE__)

      cond do
        "test" not in Path.split(filename) -> []
        Enum.any?(allowed, &String.contains?(filename, &1)) -> []
        true -> Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
      end
    end

    defp traverse(
           {{:., _, [{:__aliases__, _, [mod]}, fun]}, meta, _args} = ast,
           issues,
           issue_meta
         ) do
      if fun in Map.get(@forbidden, mod, []) do
        {ast, [flag(mod, fun, meta, issue_meta) | issues]}
      else
        {ast, issues}
      end
    end

    defp traverse(ast, issues, _issue_meta), do: {ast, issues}

    defp flag(mod, fun, meta, issue_meta) do
      format_issue(issue_meta,
        message:
          "#{mod}.#{fun} mutates global state per test (forces async: false). Inject via DI: " <>
            "read with ArenaApplication.get_env/3 and override with " <>
            "ArenaApplication.put_env/4 (process-local), or carry the value on Arena.Config. " <>
            "Production still reads Application.get_env. Only a genuine E2E hitting the real " <>
            "third party may keep it (path-allowlist it or annotate).",
        line_no: meta[:line]
      )
    end
  end
end
