defmodule Arena.Credo.ChecksTest do
  use Credo.Test.Case, async: true

  alias Arena.Credo.Check.GenServerUsesArenaProcess
  alias Arena.Credo.Check.NoApplicationPutEnvInTest
  alias Arena.Credo.Check.NoGlobalMox
  alias Arena.Credo.Check.NoTestProcessSleep

  describe "GenServerUsesArenaProcess" do
    test "flags a lib/ GenServer that does not use Arena.Process" do
      """
      defmodule MyApp.Worker do
        use GenServer
        def init(s), do: {:ok, s}
      end
      """
      |> to_source_file("lib/my_app/worker.ex")
      |> run_check(GenServerUsesArenaProcess)
      |> assert_issue()
    end

    test "no issue when the module also uses Arena.Process" do
      """
      defmodule MyApp.Worker do
        use GenServer
        use Arena.Process
      end
      """
      |> to_source_file("lib/my_app/worker.ex")
      |> run_check(GenServerUsesArenaProcess)
      |> refute_issues()
    end

    test "no issue for an exempt module" do
      """
      defmodule MyApp.Application do
        use GenServer
      end
      """
      |> to_source_file("lib/my_app/application.ex")
      |> run_check(GenServerUsesArenaProcess, exempt_modules: ["MyApp.Application"])
      |> refute_issues()
    end

    test "ignores test/ files" do
      """
      defmodule MyApp.WorkerTest do
        use GenServer
      end
      """
      |> to_source_file("test/my_app/worker_test.exs")
      |> run_check(GenServerUsesArenaProcess)
      |> refute_issues()
    end
  end

  describe "NoTestProcessSleep" do
    test "flags Process.sleep/1 in a test" do
      """
      defmodule MyTest do
        test "x" do
          Process.sleep(50)
        end
      end
      """
      |> to_source_file("test/my_test.exs")
      |> run_check(NoTestProcessSleep)
      |> assert_issue()
    end

    test "allows :infinity (a parked fixture, not sync)" do
      """
      defmodule MyTest do
        test "x" do
          Process.sleep(:infinity)
        end
      end
      """
      |> to_source_file("test/my_test.exs")
      |> run_check(NoTestProcessSleep)
      |> refute_issues()
    end

    test "ignores lib/ files" do
      """
      defmodule MyApp.Debounce do
        def wait, do: Process.sleep(50)
      end
      """
      |> to_source_file("lib/my_app/debounce.ex")
      |> run_check(NoTestProcessSleep)
      |> refute_issues()
    end
  end

  describe "NoGlobalMox" do
    test "flags set_mox_global" do
      """
      defmodule MyTest do
        setup :set_mox_global
      end
      """
      |> to_source_file("test/my_test.exs")
      |> run_check(NoGlobalMox)
      |> assert_issue()
    end

    test "no issue for private-mode (verify_on_exit!)" do
      """
      defmodule MyTest do
        setup :verify_on_exit!
      end
      """
      |> to_source_file("test/my_test.exs")
      |> run_check(NoGlobalMox)
      |> refute_issues()
    end
  end

  describe "NoApplicationPutEnvInTest" do
    test "flags Application.put_env in a test" do
      """
      defmodule MyTest do
        test "x" do
          Application.put_env(:my_app, :key, :value)
        end
      end
      """
      |> to_source_file("test/my_test.exs")
      |> run_check(NoApplicationPutEnvInTest)
      |> assert_issue()
    end

    test "no issue for Application.get_env" do
      """
      defmodule MyTest do
        test "x" do
          _ = Application.get_env(:my_app, :key)
        end
      end
      """
      |> to_source_file("test/my_test.exs")
      |> run_check(NoApplicationPutEnvInTest)
      |> refute_issues()
    end
  end
end
