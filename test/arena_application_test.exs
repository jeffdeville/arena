defmodule ArenaApplicationTest do
  use ExUnit.Case, async: true

  alias Arena.Config

  # A unique application atom per test keeps the Application.put_env fallback
  # paths from colliding across async tests (and from leaking into real apps).
  setup do
    app = :"arena_app_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> delete_app_env(app) end)
    %{app: app}
  end

  defp delete_app_env(app) do
    for {k, _v} <- Application.get_all_env(app), do: Application.delete_env(app, k)
    :ok
  end

  describe "get_env/3 — production fallback (no Arena.Config stored)" do
    test "returns the application env value when set", %{app: app} do
      Application.put_env(app, :key, :from_application)
      assert ArenaApplication.get_env(app, :key, :default) == :from_application
    end

    test "returns the default when the application env is unset", %{app: app} do
      assert ArenaApplication.get_env(app, :missing, :the_default) == :the_default
    end

    test "default arg defaults to nil", %{app: app} do
      assert ArenaApplication.get_env(app, :missing) == nil
    end

    test "is behaviour-neutral vs Application.get_env when no override is stored", %{app: app} do
      Application.put_env(app, :key, :real)
      assert ArenaApplication.get_env(app, :key, :d) == Application.get_env(app, :key, :d)
      assert ArenaApplication.get_env(app, :nope, :d) == Application.get_env(app, :nope, :d)
    end
  end

  describe "get_env/3 — Arena.Config override takes precedence" do
    test "override wins over the application env", %{app: app} do
      Application.put_env(app, :key, :from_application)

      app
      |> Config.new()
      |> ArenaApplication.put_env(app, :key, :from_override)
      |> Config.store()

      assert ArenaApplication.get_env(app, :key, :default) == :from_override
    end

    test "override wins even when no application env exists", %{app: app} do
      app
      |> Config.new()
      |> ArenaApplication.put_env(app, :key, :only_override)
      |> Config.store()

      assert ArenaApplication.get_env(app, :key, :default) == :only_override
    end

    test "an override set to nil is honoured (not treated as absent)", %{app: app} do
      Application.put_env(app, :key, :from_application)

      app
      |> Config.new()
      |> ArenaApplication.put_env(app, :key, nil)
      |> Config.store()

      assert ArenaApplication.get_env(app, :key, :default) == nil
    end
  end

  describe "the app is NOT discarded — overrides are namespaced by {app, key}" do
    test "the same key under two different apps resolves independently", %{app: app_a} do
      app_b = :"#{app_a}_b"
      on_exit(fn -> delete_app_env(app_b) end)

      config =
        app_a
        |> Config.new()
        |> ArenaApplication.put_env(app_a, :shared_key, :value_a)
        |> ArenaApplication.put_env(app_b, :shared_key, :value_b)

      Config.store(config)

      assert ArenaApplication.get_env(app_a, :shared_key) == :value_a
      assert ArenaApplication.get_env(app_b, :shared_key) == :value_b
    end

    test "an override for one app does not leak to another app's same key", %{app: app_a} do
      app_b = :"#{app_a}_b"
      Application.put_env(app_b, :shared_key, :b_from_application)
      on_exit(fn -> delete_app_env(app_b) end)

      app_a
      |> Config.new()
      |> ArenaApplication.put_env(app_a, :shared_key, :a_override)
      |> Config.store()

      # app_a has an override; app_b has none → app_b falls through to its app env.
      assert ArenaApplication.get_env(app_a, :shared_key) == :a_override
      assert ArenaApplication.get_env(app_b, :shared_key) == :b_from_application
    end
  end

  describe "fetch_env/2 and fetch_env!/2" do
    test "fetch_env returns {:ok, override} when present", %{app: app} do
      app |> Config.new() |> ArenaApplication.put_env(app, :key, :ov) |> Config.store()
      assert ArenaApplication.fetch_env(app, :key) == {:ok, :ov}
    end

    test "fetch_env falls back to Application.fetch_env", %{app: app} do
      Application.put_env(app, :key, :real)
      assert ArenaApplication.fetch_env(app, :key) == {:ok, :real}
      assert ArenaApplication.fetch_env(app, :missing) == :error
    end

    test "fetch_env! returns the override", %{app: app} do
      app |> Config.new() |> ArenaApplication.put_env(app, :key, :ov) |> Config.store()
      assert ArenaApplication.fetch_env!(app, :key) == :ov
    end

    test "fetch_env! raises when neither override nor app env is set", %{app: app} do
      assert_raise ArgumentError, fn -> ArenaApplication.fetch_env!(app, :missing) end
    end
  end

  describe "merge_env/3,4 — surgical partial overrides" do
    test "merges into the application-env base, keeping unchanged keys", %{app: app} do
      Application.put_env(app, :provider_impls, %{
        none: ProviderNone,
        google_calendar: ProviderReal,
        jobber: JobberReal
      })

      app
      |> Config.new()
      |> ArenaApplication.merge_env(app, :provider_impls, google_calendar: ProviderMock)
      |> Config.store()

      assert ArenaApplication.get_env(app, :provider_impls) == %{
               none: ProviderNone,
               google_calendar: ProviderMock,
               jobber: JobberReal
             }
    end

    test "merges into an existing override (chained merges accumulate)", %{app: app} do
      config =
        app
        |> Config.new()
        |> ArenaApplication.put_env(app, :impls, %{a: 1, b: 2, c: 3})
        |> ArenaApplication.merge_env(app, :impls, b: 20)
        |> ArenaApplication.merge_env(app, :impls, c: 30)

      Config.store(config)
      assert ArenaApplication.get_env(app, :impls) == %{a: 1, b: 20, c: 30}
    end

    test "accepts a map of changes too", %{app: app} do
      Application.put_env(app, :impls, %{a: 1, b: 2})

      app
      |> Config.new()
      |> ArenaApplication.merge_env(app, :impls, %{b: 22})
      |> Config.store()

      assert ArenaApplication.get_env(app, :impls) == %{a: 1, b: 22}
    end

    test "preserves a keyword-list base shape", %{app: app} do
      Application.put_env(app, :opts, timeout: 5_000, retries: 3)

      app
      |> Config.new()
      |> ArenaApplication.merge_env(app, :opts, timeout: 10)
      |> Config.store()

      result = ArenaApplication.get_env(app, :opts)
      assert is_list(result)
      assert Keyword.equal?(result, timeout: 10, retries: 3)
    end

    test "with no resolvable base, the changes become the (partial) value", %{app: app} do
      app
      |> Config.new()
      |> ArenaApplication.merge_env(app, :impls, google_calendar: ProviderMock)
      |> Config.store()

      assert ArenaApplication.get_env(app, :impls) == %{google_calendar: ProviderMock}
    end

    test "merging into a scalar value raises a helpful error", %{app: app} do
      Application.put_env(app, :scalar, :a_module)

      assert_raise ArgumentError, ~r/can only merge into a map or keyword list/, fn ->
        Config.new(app)
        |> ArenaApplication.merge_env(app, :scalar, key: :val)
      end
    end

    test "merge_env/3 stores into the current process config", %{app: app} do
      Config.store(Config.new(app))
      Application.put_env(app, :impls, %{a: 1, b: 2})
      ArenaApplication.merge_env(app, :impls, b: 99)
      assert ArenaApplication.get_env(app, :impls) == %{a: 1, b: 99}
    end
  end

  describe "put_env arities" do
    test "put_env/4 returns an updated config without storing it", %{app: app} do
      config = ArenaApplication.put_env(Config.new(app), app, :key, :v)

      # Returned config carries the override...
      assert %Config{} = config
      # ...but nothing was stored in the process dictionary yet.
      assert Config.current().owner == :arena_global
      assert ArenaApplication.get_env(app, :key, :default) == :default
    end

    test "put_env/3 stores into the current process config (mirrors Application.put_env/3)", %{
      app: app
    } do
      Config.store(Config.new(app))
      ArenaApplication.put_env(app, :key, :v)
      assert ArenaApplication.get_env(app, :key, :default) == :v
    end
  end
end
