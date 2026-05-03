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

  describe "process_eol/4 line assembly" do
    defp empty_acc do
      %{messages: [], raw_lines: [], buffer: "", last_read_at: 0, deadline_at: 0}
    end

    defp collector do
      pid = self()
      fn msg -> send(pid, {:on_message, msg}) end
    end

    defp drain_messages do
      receive do
        {:on_message, msg} -> [msg | drain_messages()]
      after
        0 -> []
      end
    end

    test "assembles a single :noeol + :eol pair into one logical line" do
      copilot = default_copilot(%{output_format: "json"})
      acc = %{empty_acc() | buffer: ~s({"event":"hel)}

      acc = Autopilot.process_eol(~s(lo"}), acc, copilot, collector())

      assert acc.buffer == ""
      assert acc.messages == [%{"event" => "hello"}]
      assert hd(acc.raw_lines) =~ ~s({"event":"hello"})

      assert [
               {:line, ~s({"event":"hello"})},
               {:json, %{"event" => "hello"}}
             ] = drain_messages()
    end

    test "assembles multiple :noeol chunks then :eol" do
      copilot = default_copilot(%{output_format: "json"})

      # Simulate three :noeol chunks then :eol.
      acc =
        empty_acc()
        |> Map.update!(:buffer, fn _ -> ~s({"a":) end)
        |> then(&%{&1 | buffer: &1.buffer <> ~s(1,"b":)})
        |> then(&%{&1 | buffer: &1.buffer <> ~s("two")})

      acc = Autopilot.process_eol("}", acc, copilot, collector())

      assert acc.buffer == ""
      assert acc.messages == [%{"a" => 1, "b" => "two"}]
    end

    test "buffer reset prevents carry-over into subsequent lines" do
      copilot = default_copilot(%{output_format: "json"})

      acc = Autopilot.process_eol(~s({"first":1}), %{empty_acc() | buffer: ""}, copilot, collector())
      assert acc.buffer == ""

      # Next line must NOT carry the previous content.
      acc = Autopilot.process_eol(~s({"second":2}), acc, copilot, collector())
      assert acc.buffer == ""

      assert acc.messages == [%{"second" => 2}, %{"first" => 1}]
    end

    test "redaction is applied once per assembled line, not per chunk" do
      copilot = default_copilot(%{output_format: "text"})

      # The token spans the chunk boundary; redacting per chunk would miss it.
      first_chunk = "Authorization: Bearer abcdefgh"
      second_chunk = "ijklmnop0123456789"

      acc = %{empty_acc() | buffer: first_chunk}
      _acc = Autopilot.process_eol(second_chunk, acc, copilot, collector())

      [{:line, line}] = drain_messages()
      refute line =~ "abcdefghijklmnop0123456789"
      assert line =~ "[REDACTED]"
      assert line =~ "Authorization:"
    end
  end

  describe "stall_triggered?/2" do
    # `stall_timeout_ms == 0` must disable stall detection rather than fire
    # immediately. Otherwise every run is killed as :stalled on the first
    # idle tick after start.
    test "0 disables stall detection regardless of last_read_at" do
      ancient = System.monotonic_time(:millisecond) - 10_000_000
      refute Autopilot.stall_triggered?(0, ancient)
      refute Autopilot.stall_triggered?(0, System.monotonic_time(:millisecond))
    end

    test "positive timeout fires when elapsed exceeds bound" do
      ancient = System.monotonic_time(:millisecond) - 10_000
      assert Autopilot.stall_triggered?(1_000, ancient)
    end

    test "positive timeout does not fire when fresh" do
      now = System.monotonic_time(:millisecond)
      refute Autopilot.stall_triggered?(60_000, now)
    end
  end
end
