if Code.ensure_loaded?(Credo.Check) do
  defmodule Arena.Credo.Check.NoTestProcessSleep do
    @moduledoc """
    Flags `Process.sleep/1` and `:timer.sleep/1` used as test synchronization.

    Sleeping to "wait for" an async effect couples the test to wall-clock timing
    instead of a real completion signal — the flake class Arena exists to kill.
    Replace it with `assert_receive`/`assert_received` on a real event (a PubSub
    broadcast, a GenServer reply, a telemetry event, a `{:DOWN, ...}` monitor), or
    an `assert_eventually`-style bounded poll for the genuinely no-signal case.

    A literal `:infinity` is allowed (a parked-process fixture, not sync). If a
    finite sleep is genuinely irreducible (it IS the subject under test — a
    debounce, a benchmark's synthetic workload), annotate it:

        # credo:disable-for-next-line Arena.Credo.Check.NoTestProcessSleep
        Process.sleep(50)  # <reason it cannot be an event / bounded poll>

    Only runs on `test/` files. Use `:allowed_paths` (substring match) for genuine
    HTTP/browser-boundary E2E support that has no in-VM completion signal to await.
    """

    use Credo.Check,
      base_priority: :high,
      category: :warning,
      param_defaults: [allowed_paths: []]

    alias Credo.SourceFile

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
           {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, [arg]} = ast,
           issues,
           issue_meta
         ) do
      {ast, maybe_flag(arg, meta, issues, issue_meta, "Process.sleep")}
    end

    defp traverse({{:., _, [:timer, :sleep]}, meta, [arg]} = ast, issues, issue_meta) do
      {ast, maybe_flag(arg, meta, issues, issue_meta, ":timer.sleep")}
    end

    defp traverse(ast, issues, _issue_meta), do: {ast, issues}

    defp maybe_flag(:infinity, _meta, issues, _issue_meta, _called), do: issues

    defp maybe_flag(_arg, meta, issues, issue_meta, called) do
      issue =
        format_issue(issue_meta,
          message:
            "#{called} synchronizes a test by wall clock. Use assert_receive on a real event, " <>
              "or an assert_eventually-style bounded poll. If genuinely irreducible, annotate " <>
              "`# credo:disable-for-next-line Arena.Credo.Check.NoTestProcessSleep` with a reason.",
          line_no: meta[:line]
        )

      [issue | issues]
    end
  end
end
