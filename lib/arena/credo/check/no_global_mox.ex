if Code.ensure_loaded?(Credo.Check) do
  defmodule Arena.Credo.Check.NoGlobalMox do
    @moduledoc """
    Flags global-mode Mox (`set_mox_global`, `set_mox_from_context`) in tests.

    Global Mox forces `async: false` and bleeds expectations across tests. In
    private mode Mox resolves through `$callers`; when the consuming process is not
    reachable that way (a connected LiveView process, or a Task spawned by an
    Arena-wrapped GenServer), bring the test's ownership to it instead of going
    global:

      * `Mox.allow(mock, self(), pid)` when you can reach the consuming pid (e.g. a
        LiveView's `view.pid`), or
      * `Arena.Integrations.Mox.setup(config, mocks: [...])` to carry the test's
        Mox ownership into Arena-wrapped processes (and the Tasks they spawn).

    The only legitimate global-Mox use is a genuine HTTP/browser-boundary E2E test
    (a Wallaby smoke, a Mix-task integration test) — those are `async: false`
    anyway and the consuming process is unreachable by any in-VM ownership trick.
    Exempt them via `:allowed_paths` (substring match on the test's path), or
    annotate a one-off `# credo:disable-for-next-line Arena.Credo.Check.NoGlobalMox`
    with a reason.
    """

    use Credo.Check,
      base_priority: :high,
      category: :warning,
      param_defaults: [allowed_paths: []]

    alias Credo.SourceFile

    @forbidden [:set_mox_global, :set_mox_from_context]

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

    defp traverse({:setup, meta, [fun]} = ast, issues, issue_meta) when fun in @forbidden do
      {ast, [flag(fun, meta, issue_meta) | issues]}
    end

    defp traverse(
           {{:., _, [{:__aliases__, _, [:Mox]}, fun]}, meta, _args} = ast,
           issues,
           issue_meta
         )
         when fun in @forbidden do
      {ast, [flag(fun, meta, issue_meta) | issues]}
    end

    defp traverse({fun, meta, args} = ast, issues, issue_meta)
         when fun in @forbidden and is_list(args) do
      {ast, [flag(fun, meta, issue_meta) | issues]}
    end

    defp traverse(ast, issues, _issue_meta), do: {ast, issues}

    defp flag(fun, meta, issue_meta) do
      format_issue(issue_meta,
        message:
          "Global Mox (#{fun}) forces async: false and bleeds across tests. Use private-mode " <>
            "Mox + Mox.allow/3, or Arena.Integrations.Mox for out-of-$callers consumers. " <>
            "Only a genuine HTTP-boundary E2E test may keep it (path-allowlist it or annotate).",
        line_no: meta[:line]
      )
    end
  end
end
