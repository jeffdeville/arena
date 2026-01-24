defmodule Arena.Task do
  @moduledoc """
  Task wrapper that preserves Arena configuration across async boundaries.

  `Arena.Task` wraps the standard `Task` module to ensure that spawned tasks
  inherit the Arena configuration from the parent process. This allows tasks
  to access the test's database connection, PubSub server, and other infrastructure.

  ## The Problem

  When you spawn a task with `Task.async/1`, the new process doesn't inherit
  the parent's process dictionary, which means it loses access to the Arena config.
  This breaks database access and other Arena-managed resources.

  ## The Solution

  `Arena.Task` captures the config before spawning and restores it in the task:

  1. Capture current config from parent process
  2. Spawn task with wrapped function
  3. Restore config in task process
  4. Execute callbacks (Ecto auth, etc.)
  5. Run user's function

  ## Usage

      # Instead of Task.async
      task = Arena.Task.async(fn ->
        # This function can access the database
        MyApp.Repo.get(User, 1)
      end)

      result = Task.await(task)

      # With arguments
      task = Arena.Task.async(fn user_id ->
        MyApp.Repo.get(User, user_id)
      end, [123])

      # Async stream
      user_ids = [1, 2, 3, 4, 5]
      results = Arena.Task.async_stream(user_ids, fn user_id ->
        MyApp.Repo.get(User, user_id)
      end)
      |> Enum.to_list()

  ## API Coverage

  This module wraps the most commonly used Task functions:

  - `async/1` - Spawn task with 0-arity function
  - `async/2` - Spawn task with function and args
  - `async_stream/3` - Map over enumerable with async tasks
  - `await/2` - Delegates to Task.await/2
  - `await_many/2` - Delegates to Task.await_many/2

  For other Task functions, you can manually wrap:

      config = Arena.Config.current()
      Task.start_link(fn ->
        Arena.Config.store(config)
        Arena.Config.execute_callbacks(config)
        # Your code here
      end)

  ## Examples

      # Async query
      defmodule MyApp.UserLoader do
        def load_async(user_id) do
          Arena.Task.async(fn ->
            MyApp.Repo.get(User, user_id)
          end)
        end
      end

      # Parallel processing
      defmodule MyApp.BatchProcessor do
        def process_batch(items) do
          items
          |> Arena.Task.async_stream(&process_item/1, max_concurrency: 10)
          |> Enum.to_list()
        end

        defp process_item(item) do
          # Can access database
          MyApp.Repo.insert!(...)
        end
      end

      # With timeout
      task = Arena.Task.async(fn -> slow_operation() end)
      result = Arena.Task.await(task, 5000)
  """

  alias Arena.Config

  @doc """
  Spawns an async task that preserves Arena configuration.

  Captures the current Arena config, spawns a task, and restores the config
  in the task process before executing the function.

  ## Examples

      task = Arena.Task.async(fn ->
        MyApp.Repo.get(User, 1)
      end)

      user = Task.await(task)
  """
  @spec async((-> any())) :: Task.t()
  def async(fun) when is_function(fun, 0) do
    config = Config.current()

    Task.async(fn ->
      Config.store(config)
      Config.execute_callbacks(config)
      fun.()
    end)
  end

  @doc """
  Spawns an async task with arguments, preserving Arena configuration.

  ## Examples

      task = Arena.Task.async(fn user_id ->
        MyApp.Repo.get(User, user_id)
      end, [123])

      user = Task.await(task)
  """
  @spec async((... -> any()), [any()]) :: Task.t()
  def async(fun, args) when is_function(fun) and is_list(args) do
    config = Config.current()

    Task.async(fn ->
      Config.store(config)
      Config.execute_callbacks(config)
      apply(fun, args)
    end)
  end

  @doc """
  Maps an enumerable with async tasks, preserving Arena configuration.

  This is a drop-in replacement for `Task.async_stream/3` that ensures all
  spawned tasks have access to the Arena config.

  ## Options

  All options from `Task.async_stream/3` are supported:
  - `:max_concurrency` - Maximum number of tasks to run at once (default: `System.schedulers_online/0`)
  - `:ordered` - Whether to maintain order (default: `true`)
  - `:timeout` - Timeout for each task (default: `5000`)
  - `:on_timeout` - What to do on timeout: `:exit`, `:kill_task` (default: `:exit`)
  - `:zip_input_on_exit` - Whether to return input with exit tuples (default: `false`)

  ## Examples

      user_ids = [1, 2, 3, 4, 5]

      results = Arena.Task.async_stream(user_ids, fn user_id ->
        MyApp.Repo.get(User, user_id)
      end, max_concurrency: 10)
      |> Enum.to_list()

      # With custom timeout
      results = Arena.Task.async_stream(items, &process/1, timeout: 10_000)
      |> Enum.to_list()
  """
  @spec async_stream(Enumerable.t(), (any() -> any()), keyword()) :: Enumerable.t()
  def async_stream(enumerable, fun, opts \\ []) when is_function(fun, 1) do
    config = Config.current()

    wrapped_fun = fn item ->
      Config.store(config)
      Config.execute_callbacks(config)
      fun.(item)
    end

    Task.async_stream(enumerable, wrapped_fun, opts)
  end

  @doc """
  Awaits a task reply.

  This is a simple delegation to `Task.await/2` for convenience.

  ## Examples

      task = Arena.Task.async(fn -> :result end)
      result = Arena.Task.await(task)
      #=> :result

      # With custom timeout
      result = Arena.Task.await(task, 10_000)
  """
  @spec await(Task.t(), timeout()) :: any()
  defdelegate await(task, timeout \\ 5000), to: Task

  @doc """
  Awaits multiple task replies.

  This is a simple delegation to `Task.await_many/2` for convenience.

  ## Examples

      tasks = [
        Arena.Task.async(fn -> 1 end),
        Arena.Task.async(fn -> 2 end),
        Arena.Task.async(fn -> 3 end)
      ]

      results = Arena.Task.await_many(tasks)
      #=> [1, 2, 3]

      # With custom timeout
      results = Arena.Task.await_many(tasks, 10_000)
  """
  @spec await_many([Task.t()], timeout()) :: [any()]
  defdelegate await_many(tasks, timeout \\ 5000), to: Task
end
