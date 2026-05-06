defmodule SymphonyElixir.AgentRunnerAcpxTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRunner.Acpx

  test "remote prompt runs write the prompt where the worker can read it" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-acpx-remote-prompt-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    trace_file = Path.join(test_root, "trace.log")
    remote_workspace = Path.join(test_root, "remote-workspace")
    acpx_binary = Path.join(test_root, "fake-acpx")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(remote_workspace)
    install_fake_ssh!(test_root, trace_file)
    install_fake_acpx!(acpx_binary, trace_file)

    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    write_workflow_file!(Workflow.workflow_file_path(),
      acpx_executable: acpx_binary,
      agents_routing: %{default_agent: "backend"},
      agents_registry: %{backend: %{enabled: true, acpx_agent: "codex"}}
    )

    session = %{
      agent_id: "backend",
      session_name: "session-remote",
      workspace: remote_workspace,
      worker_host: "worker-a"
    }

    assert {:ok, %{stop_reason: :completed}} =
             Acpx.run_prompt(session, "remote prompt with 'quotes'", fn _message -> :ok end)

    trace = File.read!(trace_file)

    assert trace =~ "SSH:-T worker-a bash -lc"
    assert trace =~ "PROMPT_PATH:#{remote_workspace}/.symphony/tmp/symphony_prompt_"
    assert trace =~ "PROMPT_BODY:remote prompt with 'quotes'"
    refute trace =~ "PROMPT_PATH:/tmp/symphony_prompt_"
    assert Path.wildcard(Path.join([remote_workspace, ".symphony", "tmp", "symphony_prompt_*.md"])) == []
  end

  defp install_fake_ssh!(test_root, trace_file) do
    fake_ssh = Path.join(test_root, "ssh")

    File.write!(fake_ssh, """
    #!/bin/sh
    trace_file=#{shell_escape(trace_file)}
    printf 'SSH:%s\\n' "$*" >> "$trace_file"
    last=""
    for arg in "$@"; do
      last="$arg"
    done
    sh -c "$last"
    """)

    File.chmod!(fake_ssh, 0o755)
  end

  defp install_fake_acpx!(acpx_binary, trace_file) do
    File.write!(acpx_binary, """
    #!/bin/sh
    trace_file=#{shell_escape(trace_file)}
    prompt_file=""
    prev=""
    for arg in "$@"; do
      case "$prev" in
        --file)
          prompt_file="$arg"
          ;;
      esac
      case "$arg" in
        --file=*)
          prompt_file="${arg#--file=}"
          ;;
      esac
      prev="$arg"
    done
    printf 'PROMPT_PATH:%s\\n' "$prompt_file" >> "$trace_file"
    printf 'PROMPT_BODY:' >> "$trace_file"
    cat "$prompt_file" >> "$trace_file"
    printf '\\n' >> "$trace_file"
    printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"turn-remote"}}}'
    printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
    """)

    File.chmod!(acpx_binary, 0o755)
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
