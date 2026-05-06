defmodule SymphonyElixir.StructuredLoggerTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias SymphonyElixir.Git
  alias SymphonyElixir.StructuredLogger

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    log_dir = Path.join(tmp_dir, "logs")

    # Write a minimal WORKFLOW.md with logging.directory set.
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    workflow_content = """
    ---
    tracker:
      kind: memory
    server:
      port: 4000
    logging:
      directory: #{log_dir}
      ndjson_enabled: true
      level: debug
    ---
    """

    File.write!(workflow_path, workflow_content)

    # Point the application at our temp workflow.
    original_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

    # Start a test-scoped logger so we don't interfere with the global one.
    test_name = :"StructuredLoggerTest_#{System.monotonic_time(:millisecond)}"
    {:ok, pid} = StructuredLogger.start_link(name: test_name)

    on_exit(fn ->
      if original_workflow do
        SymphonyElixir.Workflow.set_workflow_file_path(original_workflow)
      else
        SymphonyElixir.Workflow.clear_workflow_file_path()
      end

      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    {:ok, log_dir: log_dir, logger: test_name}
  end

  test "writes info event as NDJSON line", %{log_dir: log_dir, logger: logger} do
    StructuredLogger.info(logger, "test message", issue_id: "issue-123")
    StructuredLogger.flush(logger)

    files = File.ls!(log_dir)
    assert length(files) == 1

    [file] = files
    path = Path.join(log_dir, file)
    assert String.ends_with?(file, ".ndjson")

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 1

    decoded = Jason.decode!(hd(lines))
    assert decoded["message"] == "test message"
    assert decoded["level"] == "info"
    assert decoded["issue_id"] == "issue-123"
    assert decoded["service"] == "symphony"
    assert is_binary(decoded["@timestamp"])
  end

  test "writes multiple events to the same daily file", %{log_dir: log_dir, logger: logger} do
    StructuredLogger.info(logger, "first")
    StructuredLogger.error(logger, "second", issue_identifier: "MT-1")
    StructuredLogger.flush(logger)

    files = File.ls!(log_dir)
    assert length(files) == 1

    [file] = files
    lines = Path.join(log_dir, file) |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2

    [first, second] = lines |> Enum.map(&Jason.decode!/1)
    assert first["message"] == "first"
    assert first["level"] == "info"
    assert second["message"] == "second"
    assert second["level"] == "error"
    assert second["issue_identifier"] == "MT-1"
  end

  test "drops events below configured level", %{tmp_dir: tmp_dir, logger: logger} do
    log_dir = Path.join(tmp_dir, "logs")

    # Re-configure with level warning.
    workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)

    workflow_content = """
    ---
    tracker:
      kind: memory
    server:
      port: 4000
    logging:
      directory: #{log_dir}
      ndjson_enabled: true
      level: warning
    ---
    """

    File.write!(workflow_path, workflow_content)
    SymphonyElixir.WorkflowStore.force_reload()

    # Restart logger so it picks up new config.
    GenServer.stop(logger)
    Process.sleep(50)

    test_name = :"StructuredLoggerTest_#{System.monotonic_time(:millisecond)}"
    {:ok, pid} = StructuredLogger.start_link(name: test_name)

    StructuredLogger.debug(test_name, "debug msg")
    StructuredLogger.info(test_name, "info msg")
    StructuredLogger.warning(test_name, "warning msg")
    StructuredLogger.flush(test_name)

    files = File.ls!(log_dir)
    assert length(files) == 1

    [file] = files
    lines = Path.join(log_dir, file) |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 1

    decoded = Jason.decode!(hd(lines))
    assert decoded["message"] == "warning msg"

    GenServer.stop(pid)
  end

  test "is no-op when ndjson_enabled is false", %{tmp_dir: tmp_dir, logger: logger} do
    log_dir = Path.join(tmp_dir, "logs_disabled")
    workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)

    workflow_content = """
    ---
    tracker:
      kind: memory
    server:
      port: 4000
    logging:
      directory: #{log_dir}
      ndjson_enabled: false
    ---
    """

    File.write!(workflow_path, workflow_content)
    SymphonyElixir.WorkflowStore.force_reload()

    GenServer.stop(logger)
    Process.sleep(50)

    test_name = :"StructuredLoggerTest_#{System.monotonic_time(:millisecond)}"
    {:ok, pid} = StructuredLogger.start_link(name: test_name)

    StructuredLogger.info(test_name, "should not appear")
    StructuredLogger.flush(test_name)

    refute File.exists?(log_dir)

    GenServer.stop(pid)
  end

  test "log/1 accepts arbitrary map fields", %{log_dir: log_dir, logger: logger} do
    StructuredLogger.log(logger, %{
      level: :info,
      message: "custom event",
      session_id: "sess-42",
      extra: %{foo: "bar"}
    })

    StructuredLogger.flush(logger)

    [file] = File.ls!(log_dir)
    lines = Path.join(log_dir, file) |> File.read!() |> String.split("\n", trim: true)
    decoded = Jason.decode!(hd(lines))

    assert decoded["message"] == "custom event"
    assert decoded["session_id"] == "sess-42"
    assert decoded["extra"]["foo"] == "bar"
  end

  test "log_named/2 writes required agent run proof fields", %{log_dir: log_dir} do
    StructuredLogger.log_named("agent-runs", %{
      run_id: "run-1",
      agent_id: "codex",
      acpx_session_name: "session-1",
      workspace_path: "/tmp/workspace",
      event_type: "agent_run_started",
      severity: "info",
      message: "started",
      payload: %{
        agent_execution_backend: "acpx",
        selected_agent: "codex",
        spawned_executable: "acpx",
        direct_agent_spawn: false,
        argv: ["codex"],
        cwd: "/tmp/workspace",
        environment_keys: ["PATH"]
      }
    })

    path = Path.join(log_dir, "agent-runs.ndjson")
    [line] = path |> File.read!() |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)

    assert decoded["payload"]["agent_execution_backend"] == "acpx"
    assert decoded["payload"]["direct_agent_spawn"] == false
    assert decoded["payload"]["spawned_executable"] == "acpx"
  end

  test "git command wrapper writes git.ndjson events", %{log_dir: log_dir} do
    assert {_output, 0} = Git.cmd(["--version"], stderr_to_stdout: true)

    path = Path.join(log_dir, "git.ndjson")
    [line] = path |> File.read!() |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)

    assert decoded["event_type"] == "git_command"
    assert decoded["payload"]["executable"] == "git"
    assert decoded["payload"]["exit_code"] == 0
    assert decoded["payload"]["argv"] == ["--version"]
  end
end
