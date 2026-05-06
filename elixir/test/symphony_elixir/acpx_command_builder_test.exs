defmodule SymphonyElixir.Acpx.CommandBuilderTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Acpx.CommandBuilder

  describe "prompt/4" do
    test "uses configured acpx agent as an argv argument" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{default_agent: "backend"},
        agents_registry: %{
          backend: %{
            enabled: true,
            acpx_agent: "codex",
            permissions: %{mode: "approve-reads"},
            runtime: %{timeout_seconds: 120, ttl_seconds: 30}
          }
        }
      )

      argv = CommandBuilder.prompt("backend", "/tmp/workspace", "session-a", "/tmp/prompt.md")

      assert CommandBuilder.executable() == "acpx"
      assert "codex" in argv
      refute Enum.any?(argv, &String.starts_with?(&1, "--agent"))

      assert argv == [
               "--cwd",
               "/tmp/workspace",
               "--format",
               "json",
               "--approve-reads",
               "--json-strict",
               "--suppress-reads",
               "--timeout",
               "120",
               "--ttl",
               "30",
               "codex",
               "-s",
               "session-a",
               "--file",
               "/tmp/prompt.md"
             ]
    end

    test "passes custom ACP command through acpx --agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{default_agent: "custom"},
        agents_registry: %{
          custom: %{
            enabled: true,
            custom_acpx_agent_command: "./bin/custom-agent acp",
            permissions: %{mode: "approve-all"},
            runtime: %{timeout_seconds: 60, ttl_seconds: 15}
          }
        }
      )

      argv = CommandBuilder.prompt("custom", "/tmp/workspace", "session-a", "/tmp/prompt.md")

      assert "--agent" in argv
      assert "./bin/custom-agent acp" in argv
      refute "custom" in argv
    end

    test "applies opaque per-agent model config when enabled" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{default_agent: "backend"},
        agents_registry: %{
          backend: %{
            enabled: true,
            acpx_agent: "claude",
            model: %{
              enabled: true,
              config_key: "model",
              value: "user-configured-model",
              on_unsupported: "warn"
            }
          }
        }
      )

      argv = CommandBuilder.prompt("backend", "/tmp/workspace", "session-a", "/tmp/prompt.md")

      assert "--config" in argv
      assert "model=user-configured-model" in argv
    end
  end

  describe "ensure_session/3" do
    test "builds sessions ensure argv through selected acpx agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{default_agent: "backend"},
        agents_registry: %{backend: %{enabled: true, acpx_agent: "opencode"}}
      )

      assert CommandBuilder.ensure_session("backend", "/tmp/workspace", "session-a") ==
               [
                 "--cwd",
                 "/tmp/workspace",
                 "--format",
                 "json",
                 "--approve-all",
                 "--json-strict",
                 "--suppress-reads",
                 "--timeout",
                 "3600",
                 "--ttl",
                 "300",
                 "opencode",
                 "sessions",
                 "ensure",
                 "--name",
                 "session-a"
               ]
    end
  end
end
