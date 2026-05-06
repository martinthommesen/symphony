defmodule SymphonyElixir.StructuredLogger do
  @moduledoc """
  Writes structured log events as NDJSON (newline-delimited JSON) lines.

  Each log entry is a single JSON object with standard fields:

    - `@timestamp`  – ISO-8601 UTC timestamp
    - `level`       – atom level (`info`, `error`, `warning`, `debug`)
    - `message`     – human-readable message
    - `service`     – always `"symphony"`

  Additional context fields (issue_id, issue_identifier, session_id, etc.)
  are merged in when provided.

  The logger reads its directory and enabled flag from
  `Config.settings!().logging`.  When disabled or mis-configured it
  silently drops events so that logging never crashes the caller.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Redaction

  @default_relative_dir ".symphony/logs"
  @service "symphony"

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec log(GenServer.server(), map()) :: :ok
  def log(server \\ __MODULE__, event) when is_map(event) do
    GenServer.cast(server, {:log, event})
  end

  @spec log_named(String.t(), map()) :: :ok
  def log_named(name, event) when is_binary(name) and is_map(event) do
    case named_logging_config() do
      {_directory, false} ->
        :ok

      {directory, true} ->
        path = Path.join(directory, "#{name}.ndjson")

        with {:ok, event} <- normalize_named_event(event),
             :ok <- File.mkdir_p(directory),
             {:ok, encoded} <- Jason.encode(event),
             :ok <- File.write(path, encoded <> "\n", [:append]) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("StructuredLogger named write failed for #{path}: #{inspect(reason)}")
            :ok
        end
    end
  end

  @spec info(GenServer.server(), String.t(), keyword()) :: :ok
  def info(server \\ __MODULE__, message, opts \\ []) when is_binary(message) do
    log(server, build_event(:info, message, opts))
  end

  @spec error(GenServer.server(), String.t(), keyword()) :: :ok
  def error(server \\ __MODULE__, message, opts \\ []) when is_binary(message) do
    log(server, build_event(:error, message, opts))
  end

  @spec warning(GenServer.server(), String.t(), keyword()) :: :ok
  def warning(server \\ __MODULE__, message, opts \\ []) when is_binary(message) do
    log(server, build_event(:warning, message, opts))
  end

  @spec debug(GenServer.server(), String.t(), keyword()) :: :ok
  def debug(server \\ __MODULE__, message, opts \\ []) when is_binary(message) do
    log(server, build_event(:debug, message, opts))
  end

  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush)
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct [:directory, :enabled, :level, :current_date, :io_device]
  end

  @impl true
  def init(_opts) do
    {directory, enabled, level} = read_logging_config()

    state = %State{
      directory: directory,
      enabled: enabled,
      level: level,
      current_date: nil,
      io_device: nil
    }

    {:ok, open_log_file(state)}
  end

  @impl true
  def handle_cast({:log, event}, state) do
    if state.enabled and level_allowed?(event[:level], state.level) do
      state = ensure_file_open(state)
      write_event(state.io_device, event)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    if state.io_device do
      :file.sync(state.io_device)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.io_device do
      File.close(state.io_device)
    end

    :ok
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp read_logging_config do
    settings = Config.settings!()
    logging = settings.logging

    dir =
      if is_binary(logging.directory) and logging.directory != "" do
        Path.expand(logging.directory)
      else
        Path.expand(@default_relative_dir)
      end

    level = parse_level(logging.level)
    {dir, logging.ndjson_enabled, level}
  rescue
    _ ->
      {Path.expand(@default_relative_dir), true, :info}
  end

  defp configured_directory do
    settings = Config.settings!()
    logging = settings.logging

    if is_binary(logging.directory) and logging.directory != "" do
      Path.expand(logging.directory)
    else
      Path.expand(@default_relative_dir)
    end
  rescue
    _ -> Path.expand(@default_relative_dir)
  end

  defp named_logging_config do
    settings = Config.settings!()
    logging = settings.logging
    directory = configured_directory()

    {directory, logging.ndjson_enabled}
  rescue
    _ -> {Path.expand(@default_relative_dir), true}
  end

  defp parse_level(nil), do: :info
  defp parse_level(level) when is_atom(level), do: level

  defp parse_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "warn" -> :warning
      "error" -> :error
      _ -> :info
    end
  end

  defp level_allowed?(_event_level, nil), do: true

  defp level_allowed?(event_level, threshold) do
    level_value(event_level) >= level_value(threshold)
  end

  defp level_value(:debug), do: 0
  defp level_value(:info), do: 1
  defp level_value(:warning), do: 2
  defp level_value(:error), do: 3
  defp level_value(_), do: 1

  defp open_log_file(%State{enabled: false} = state), do: state

  defp open_log_file(%State{} = state) do
    date = Date.utc_today()
    path = log_file_path(state.directory, date)

    case File.mkdir_p(state.directory) do
      :ok ->
        case File.open(path, [:append, :raw, :binary, :utf8]) do
          {:ok, io_device} ->
            %State{state | current_date: date, io_device: io_device}

          {:error, reason} ->
            Logger.warning("StructuredLogger failed to open #{path}: #{inspect(reason)}")

            %State{state | current_date: date, io_device: nil}
        end

      {:error, reason} ->
        Logger.warning("StructuredLogger failed to create directory #{state.directory}: #{inspect(reason)}")

        %State{state | current_date: date, io_device: nil}
    end
  end

  defp ensure_file_open(%State{current_date: nil} = state), do: open_log_file(state)

  defp ensure_file_open(%State{} = state) do
    today = Date.utc_today()

    if state.current_date == today and state.io_device != nil do
      state
    else
      if state.io_device do
        File.close(state.io_device)
      end

      open_log_file(%State{state | current_date: nil, io_device: nil})
    end
  end

  defp log_file_path(directory, date) do
    filename = "symphony-#{Date.to_iso8601(date)}.ndjson"
    Path.join(directory, filename)
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp write_event(nil, _event), do: :ok

  defp write_event(io_device, event) do
    with {:ok, event} <- redact_event(event),
         event <- event |> Map.put(:"@timestamp", timestamp()) |> Map.put(:service, @service),
         {:ok, line} <- Jason.encode(event),
         :ok <- IO.binwrite(io_device, [line, "\n"]) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("StructuredLogger dropped event: #{inspect(reason)}")
        :ok
    end
  end

  defp build_event(level, message, opts) when is_list(opts) do
    opts
    |> Enum.into(%{})
    |> Map.put(:level, level)
    |> Map.put(:message, message)
  end

  defp normalize_named_event(event) do
    with {:ok, event} <- redact_event(event) do
      {:ok,
       event
       |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
       |> Map.put_new(:severity, "info")
       |> Map.put_new(:event_type, "event")
       |> Map.put_new(:message, "")
       |> Map.put_new(:payload, %{})}
    end
  end

  defp redact_event(event) when is_map(event) do
    with {:ok, encoded} <- Jason.encode(event),
         redacted <- Redaction.redact(encoded),
         {:ok, decoded} <- Jason.decode(redacted) do
      {:ok, atomize_known_keys(decoded)}
    end
  end

  defp atomize_known_keys(event) do
    Enum.reduce(event, %{}, fn {key, value}, acc ->
      Map.put(acc, known_key(key), value)
    end)
  end

  defp known_key(key)
       when key in [
              "timestamp",
              "run_id",
              "issue_number",
              "issue_id",
              "agent_id",
              "acpx_session_name",
              "workspace_path",
              "branch_name",
              "event_type",
              "severity",
              "message",
              "payload"
            ] do
    String.to_atom(key)
  end

  defp known_key(key), do: key
end
