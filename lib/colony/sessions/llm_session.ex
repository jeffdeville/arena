defmodule Colony.Sessions.LlmSession do
  @moduledoc """
  Captures LLM session output to log files.

  Each session writes its output to a dedicated log file under the configured
  log directory. Sessions are identified by a unique session ID.
  """

  @default_log_dir "logs/sessions"

  defstruct [:id, :log_dir, :log_path, :started_at]

  @type t :: %__MODULE__{
          id: String.t(),
          log_dir: String.t(),
          log_path: String.t(),
          started_at: DateTime.t()
        }

  @doc """
  Starts a new session and creates its log file.

  ## Options
    * `:log_dir` - Directory for log files (default: `#{@default_log_dir}`)
    * `:id` - Session ID (default: auto-generated UUID)
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts \\ []) do
    id = Keyword.get(opts, :id, generate_id())
    log_dir = Keyword.get(opts, :log_dir, @default_log_dir)
    log_path = Path.join(log_dir, "#{id}.log")

    with :ok <- File.mkdir_p(log_dir) do
      session = %__MODULE__{
        id: id,
        log_dir: log_dir,
        log_path: log_path,
        started_at: DateTime.utc_now()
      }

      write_line(session, "Session started: #{session.id}")
      {:ok, session}
    end
  end

  @doc """
  Captures output to the session log file.
  """
  @spec capture(t(), String.t()) :: :ok | {:error, term()}
  def capture(%__MODULE__{log_path: log_path}, output) when is_binary(output) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    line = "[#{timestamp}] #{output}\n"
    File.write(log_path, line, [:append])
  end

  @doc """
  Reads the full session log.
  """
  @spec read_log(t()) :: {:ok, String.t()} | {:error, term()}
  def read_log(%__MODULE__{log_path: log_path}) do
    File.read(log_path)
  end

  @doc """
  Returns the log file path for the session.
  """
  @spec log_path(t()) :: String.t()
  def log_path(%__MODULE__{log_path: path}), do: path

  defp write_line(%__MODULE__{log_path: log_path}, content) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write(log_path, "[#{timestamp}] #{content}\n", [:append])
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
