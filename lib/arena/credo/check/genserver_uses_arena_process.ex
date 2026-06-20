# Compiled only when Credo is available (an optional dependency). In a production
# build without Credo this module is simply skipped; a project that runs Credo
# always has it, so the check is present whenever `mix credo` runs.
if Code.ensure_loaded?(Credo.Check) do
  defmodule Arena.Credo.Check.GenServerUsesArenaProcess do
    @moduledoc """
    Fail-closed: a `lib/` module that `use GenServer` must ALSO `use Arena.Process`
    — or be listed in `:exempt_modules`.

    Arena gives a per-test GenServer its own Registry-scoped instance via
    `via_tuple()`, so async tests that spawn it don't cross-talk. A new GenServer
    that silently skips Arena registers as a global singleton and collides under
    `async: true`. This check forces a DELIBERATE choice for every GenServer:
    convert it (`use Arena.Process` + `to_process_key/1`) OR record an explicit
    exemption.

    Legitimate exemptions are genuinely-global singletons — an
    application-supervised process started once in `Application.start/2`, or a
    named ETS owner. List them in `:exempt_modules` (full module name or the last
    segment). Only scans `lib/`.

        # .credo.exs
        {Arena.Credo.Check.GenServerUsesArenaProcess,
         [exempt_modules: ["MyApp.Application", "MyApp.GlobalCache"]]}
    """

    use Credo.Check,
      base_priority: :high,
      category: :warning,
      param_defaults: [exempt_modules: []]

    alias Credo.SourceFile

    @impl true
    def run(%SourceFile{filename: filename} = source_file, params) do
      if "lib" in Path.split(filename) do
        issues(source_file, params)
      else
        []
      end
    end

    defp issues(source_file, params) do
      issue_meta = IssueMeta.for(source_file, params)
      exempt = Params.get(params, :exempt_modules, __MODULE__)

      facts =
        Credo.Code.prewalk(
          source_file,
          &collect/2,
          %{genserver_line: nil, arena?: false, module: nil}
        )

      cond do
        is_nil(facts.genserver_line) -> []
        facts.arena? -> []
        exempt?(facts.module, exempt) -> []
        true -> [flag(facts, issue_meta)]
      end
    end

    defp collect({:use, meta, [{:__aliases__, _, [:GenServer]} | _]} = ast, acc) do
      {ast, Map.update(acc, :genserver_line, meta[:line], &(&1 || meta[:line]))}
    end

    defp collect({:use, _, [{:__aliases__, _, [:Arena, :Process]} | _]} = ast, acc) do
      {ast, %{acc | arena?: true}}
    end

    defp collect({:defmodule, _, [{:__aliases__, _, parts} | _]} = ast, acc) do
      module = Enum.map_join(parts, ".", &Atom.to_string/1)
      {ast, Map.update(acc, :module, module, &(&1 || module))}
    end

    defp collect(ast, acc), do: {ast, acc}

    defp exempt?(nil, _exempt), do: false

    defp exempt?(module, exempt) do
      short = module |> String.split(".") |> List.last()
      Enum.any?(exempt, fn e -> e == module or e == short end)
    end

    defp flag(facts, issue_meta) do
      format_issue(issue_meta,
        message:
          "#{facts.module || "This module"} uses GenServer but not Arena.Process. Add " <>
            "`use Arena.Process` + `@impl Arena.Process def to_process_key(_), do: __MODULE__` " <>
            "so async tests get an isolated instance — OR, if it is a deliberate global " <>
            "(application-supervised / pid-keyed) singleton, add it to :exempt_modules.",
        line_no: facts.genserver_line
      )
    end
  end
end
