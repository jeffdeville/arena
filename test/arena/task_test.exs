defmodule Arena.TaskTest do
  use ExUnit.Case, async: true

  alias Arena.Config
  alias Arena.Task, as: ArenaTask

  describe "async/1" do
    test "spawns task that preserves config" do
      config = Config.new(:test_task)
      Config.store(config)

      task = ArenaTask.async(fn ->
        # Config should be available in task
        Config.current()
      end)

      result = Task.await(task)

      assert result.owner == :test_task
    end

    test "executes callbacks in task" do
      parent = self()
      callback = {__MODULE__, :test_callback, [parent: parent]}

      config = Config.new(:test_task_callback, callbacks: [callback])
      Config.store(config)

      task = ArenaTask.async(fn ->
        :done
      end)

      Task.await(task)

      # Should receive callback execution from task
      assert_receive {:callback_executed, %Config{}}
    end

    test "task function executes and returns result" do
      config = Config.new(:test_task_result)
      Config.store(config)

      task = ArenaTask.async(fn ->
        {:ok, :result}
      end)

      assert {:ok, :result} = Task.await(task)
    end
  end

  describe "async/2" do
    test "spawns task with arguments" do
      config = Config.new(:test_task_args)
      Config.store(config)

      task = ArenaTask.async(fn a, b -> a + b end, [1, 2])

      assert 3 = Task.await(task)
    end

    test "preserves config with arguments" do
      config = Config.new(:test_task_args_config)
      Config.store(config)

      task = ArenaTask.async(
        fn arg ->
          {arg, Config.current()}
        end,
        [:my_arg]
      )

      {arg, task_config} = Task.await(task)

      assert arg == :my_arg
      assert task_config.owner == :test_task_args_config
    end
  end

  describe "async_stream/3" do
    test "maps enumerable with config preserved" do
      config = Config.new(:test_stream)
      Config.store(config)

      results =
        ArenaTask.async_stream([1, 2, 3], fn x ->
          # Config should be available
          config = Config.current()
          {x * 2, config.owner}
        end)
        |> Enum.to_list()

      assert results == [
               ok: {2, :test_stream},
               ok: {4, :test_stream},
               ok: {6, :test_stream}
             ]
    end

    test "executes callbacks for each task" do
      parent = self()
      callback = {__MODULE__, :test_callback, [parent: parent, id: :stream]}

      config = Config.new(:test_stream_callbacks, callbacks: [callback])
      Config.store(config)

      results =
        ArenaTask.async_stream([1, 2], fn x -> x end)
        |> Enum.to_list()

      assert results == [ok: 1, ok: 2]

      # Should receive callback execution from each task
      assert_receive {:callback_executed, %Config{}, :stream}
      assert_receive {:callback_executed, %Config{}, :stream}
    end

    test "respects max_concurrency option" do
      config = Config.new(:test_stream_concurrency)
      Config.store(config)

      results =
        ArenaTask.async_stream([1, 2, 3, 4], fn x -> x * 2 end, max_concurrency: 2)
        |> Enum.to_list()

      assert results == [ok: 2, ok: 4, ok: 6, ok: 8]
    end

    test "respects timeout option" do
      config = Config.new(:test_stream_timeout)
      Config.store(config)

      results =
        ArenaTask.async_stream(
          [1],
          fn _x ->
            Process.sleep(100)
            :done
          end,
          timeout: 200
        )
        |> Enum.to_list()

      assert results == [ok: :done]
    end

    test "handles timeout correctly" do
      config = Config.new(:test_stream_timeout_exceeded)
      Config.store(config)

      results =
        ArenaTask.async_stream(
          [1],
          fn _x ->
            Process.sleep(200)
            :done
          end,
          timeout: 50,
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      assert [{:exit, :timeout}] = results
    end
  end

  describe "await/2" do
    test "delegates to Task.await" do
      config = Config.new(:test_await)
      Config.store(config)

      task = ArenaTask.async(fn -> :result end)
      result = ArenaTask.await(task)

      assert result == :result
    end

    test "respects custom timeout" do
      config = Config.new(:test_await_timeout)
      Config.store(config)

      task = ArenaTask.async(fn ->
        Process.sleep(50)
        :done
      end)

      result = ArenaTask.await(task, 100)
      assert result == :done
    end
  end

  describe "await_many/2" do
    test "awaits multiple tasks" do
      config = Config.new(:test_await_many)
      Config.store(config)

      tasks = [
        ArenaTask.async(fn -> 1 end),
        ArenaTask.async(fn -> 2 end),
        ArenaTask.async(fn -> 3 end)
      ]

      results = ArenaTask.await_many(tasks)

      assert results == [1, 2, 3]
    end

    test "all tasks have config" do
      config = Config.new(:test_await_many_config)
      Config.store(config)

      tasks = [
        ArenaTask.async(fn -> Config.current().owner end),
        ArenaTask.async(fn -> Config.current().owner end),
        ArenaTask.async(fn -> Config.current().owner end)
      ]

      results = ArenaTask.await_many(tasks)

      assert results == [
               :test_await_many_config,
               :test_await_many_config,
               :test_await_many_config
             ]
    end

    test "respects custom timeout" do
      config = Config.new(:test_await_many_timeout)
      Config.store(config)

      tasks = [
        ArenaTask.async(fn ->
          Process.sleep(50)
          :done
        end)
      ]

      results = ArenaTask.await_many(tasks, 100)
      assert results == [:done]
    end
  end

  # Helper for testing callbacks
  def test_callback(config, opts \\ []) do
    parent = Keyword.get(opts, :parent)
    id = Keyword.get(opts, :id)

    if parent do
      if id do
        send(parent, {:callback_executed, config, id})
      else
        send(parent, {:callback_executed, config})
      end
    end
  end
end
