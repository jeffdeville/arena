defmodule Colony.Sessions.LlmSessionTest do
  use ExUnit.Case, async: true

  alias Colony.Sessions.LlmSession

  @moduletag :tmp_dir

  describe "start/1" do
    test "creates a session with a log file", %{tmp_dir: tmp_dir} do
      assert {:ok, session} = LlmSession.start(log_dir: tmp_dir)
      assert session.id
      assert session.log_path
      assert session.started_at
      assert File.exists?(session.log_path)
    end

    test "uses a custom session ID", %{tmp_dir: tmp_dir} do
      assert {:ok, session} = LlmSession.start(id: "test-session", log_dir: tmp_dir)
      assert session.id == "test-session"
      assert String.ends_with?(session.log_path, "test-session.log")
    end

    test "log file contains session started entry", %{tmp_dir: tmp_dir} do
      {:ok, session} = LlmSession.start(id: "my-session", log_dir: tmp_dir)
      {:ok, contents} = File.read(session.log_path)
      assert contents =~ "Session started: my-session"
    end
  end

  describe "capture/2" do
    test "writes output to the log file", %{tmp_dir: tmp_dir} do
      {:ok, session} = LlmSession.start(log_dir: tmp_dir)

      assert :ok = LlmSession.capture(session, "Hello from LLM")

      {:ok, contents} = LlmSession.read_log(session)
      assert contents =~ "Hello from LLM"
    end

    test "appends multiple outputs", %{tmp_dir: tmp_dir} do
      {:ok, session} = LlmSession.start(log_dir: tmp_dir)

      LlmSession.capture(session, "First output")
      LlmSession.capture(session, "Second output")

      {:ok, contents} = LlmSession.read_log(session)
      assert contents =~ "First output"
      assert contents =~ "Second output"
    end

    test "includes timestamps in log entries", %{tmp_dir: tmp_dir} do
      {:ok, session} = LlmSession.start(log_dir: tmp_dir)

      LlmSession.capture(session, "Timestamped output")

      {:ok, contents} = LlmSession.read_log(session)
      # ISO 8601 timestamp pattern
      assert contents =~ ~r/\[\d{4}-\d{2}-\d{2}T/
    end
  end

  describe "read_log/1" do
    test "returns the full log contents", %{tmp_dir: tmp_dir} do
      {:ok, session} = LlmSession.start(id: "readable", log_dir: tmp_dir)
      LlmSession.capture(session, "line one")
      LlmSession.capture(session, "line two")

      {:ok, contents} = LlmSession.read_log(session)
      assert contents =~ "Session started: readable"
      assert contents =~ "line one"
      assert contents =~ "line two"
    end
  end

  describe "log_path/1" do
    test "returns the path to the log file", %{tmp_dir: tmp_dir} do
      {:ok, session} = LlmSession.start(id: "path-test", log_dir: tmp_dir)
      assert LlmSession.log_path(session) == Path.join(tmp_dir, "path-test.log")
    end
  end
end
