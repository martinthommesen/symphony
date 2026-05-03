defmodule SymphonyElixir.Copilot.AutopilotTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Copilot.Autopilot

  defp default_copilot(overrides \\ %{}) do
    base = %{
      command: "copilot",
      mode: "autopilot",
      permission_mode: "yolo",
      no_ask_user: true,
      output_format: "json",
      max_autopilot_continues: 10,
      turn_timeout_ms: 3_600_000,
      read_timeout_ms: 5_000,
      stall_timeout_ms: 300_000,
      deny_tools: ["shell(git push)", "shell(gh pr)", "shell(gh issue)"]
    }

    Map.merge(base, overrides)
  end

  describe "build_argv/2" do
    test "builds default autopilot argv with prompt as -p" do
      argv = Autopilot.build_argv(default_copilot(), "do the thing")

      assert "--autopilot" in argv
      assert "--yolo" in argv
      assert "--no-ask-user" in argv
      assert "--max-autopilot-continues=10" in argv
      assert "--output-format=json" in argv
      assert "-p" in argv

      [_p, prompt] = Enum.drop(argv, length(argv) - 2)
      assert prompt == "do the thing"
    end

    test "appends each deny tool as --deny-tool=<pattern>" do
      argv = Autopilot.build_argv(default_copilot(), "p")

      assert "--deny-tool=shell(git push)" in argv
      assert "--deny-tool=shell(gh pr)" in argv
      assert "--deny-tool=shell(gh issue)" in argv
    end

    test "supports text output format" do
      argv = Autopilot.build_argv(default_copilot(%{output_format: "text"}), "p")
      assert "--output-format=text" in argv
      refute "--output-format=json" in argv
    end

    test "omits --no-ask-user when no_ask_user: false" do
      argv = Autopilot.build_argv(default_copilot(%{no_ask_user: false}), "p")
      refute "--no-ask-user" in argv
    end

    test "omits --yolo unless permission_mode is yolo" do
      ask_argv = Autopilot.build_argv(default_copilot(%{permission_mode: "ask"}), "p")
      refute "--yolo" in ask_argv

      restricted_argv = Autopilot.build_argv(default_copilot(%{permission_mode: "restricted"}), "p")
      refute "--yolo" in restricted_argv

      yolo_argv = Autopilot.build_argv(default_copilot(%{permission_mode: "yolo"}), "p")
      assert "--yolo" in yolo_argv
    end

    test "passes prompt as the final two argv entries (argv-only, never shell)" do
      argv = Autopilot.build_argv(default_copilot(), "prompt with $shell `chars`")
      assert List.last(argv) == "prompt with $shell `chars`"
      assert Enum.at(argv, length(argv) - 2) == "-p"
    end
  end
end
