defmodule SymphonyElixir.StaticGuardrailTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Static guardrail tests that fail if production code reintroduces
  direct agent spawning outside of acpx.
  """

  @production_lib_path Path.join(__DIR__, "../../lib")

  # Forbidden runtime binary spawn patterns.
  # These must only appear in docs, tests, config examples, or installer/doctor checks.
  @forbidden_patterns [
    ~r/"codex\s/,
    ~r/"claude\s/,
    ~r/"copilot\s/,
    ~r/"gemini\s/,
    ~r/"cursor-agent\s/,
    ~r/"opencode\s/,
    ~r/"qwen\s/
  ]

  # Files that are allowed to contain forbidden patterns.
  # These are docs, config, tests, installer/doctor, and backward-compat helpers.
  @allowlist [
    ~r{lib/symphony_elixir/config/schema\.ex$},
    ~r{lib/symphony_elixir/status_dashboard\.ex$},
    ~r{lib/symphony_elixir/cli\.ex$},
    ~r{lib/symphony_elixir/workspace\.ex$}
  ]

  test "production runner module is AgentRunner.Acpx only" do
    lib_path = Path.expand(@production_lib_path)

    runner_modules =
      lib_path
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        String.contains?(path, "runner") or String.contains?(path, " Runner")
      end)
      |> Enum.map(&Path.relative_to(&1, lib_path))

    assert "symphony_elixir/agent_runner.ex" in runner_modules
    assert "symphony_elixir/agent_runner/acpx.ex" in runner_modules

    # No legacy runner modules.
    refute "symphony_elixir/codex_runner.ex" in runner_modules
    refute "symphony_elixir/copilot_runner.ex" in runner_modules
    refute "symphony_elixir/claude_runner.ex" in runner_modules
    refute "symphony_elixir/gemini_runner.ex" in runner_modules
    refute "symphony_elixir/cursor_runner.ex" in runner_modules
    refute "symphony_elixir/opencode_runner.ex" in runner_modules
    refute "symphony_elixir/qwen_runner.ex" in runner_modules
  end

  test "command builder always uses config.acpx.executable as executable" do
    command_builder_path =
      @production_lib_path
      |> Path.join("symphony_elixir/acpx/command_builder.ex")
      |> Path.expand()

    assert File.exists?(command_builder_path)

    source = File.read!(command_builder_path)

    # executable/0 must read from Config.acpx_executable().
    assert source =~ "Config.acpx_executable()"

    # Must not hard-code any forbidden binary as the executable.
    for pattern <- @forbidden_patterns do
      refute Regex.match?(pattern, source),
             "CommandBuilder must not hard-code forbidden binary pattern: #{inspect(pattern)}"
    end
  end

  test "no production code hard-codes forbidden binary spawn patterns" do
    lib_path = Path.expand(@production_lib_path)

    production_files =
      lib_path
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        Enum.any?(@allowlist, &Regex.match?(&1, path))
      end)

    violations =
      for path <- production_files,
          pattern <- @forbidden_patterns,
          source = File.read!(path),
          Regex.match?(pattern, source) do
        {Path.relative_to(path, lib_path), inspect(pattern)}
      end

    assert violations == [],
           "Forbidden runtime binary spawn patterns found in production code: #{inspect(violations)}"
  end

  test "AgentRunner.Acpx only spawns configured acpx executable" do
    acpx_runner_path =
      @production_lib_path
      |> Path.join("symphony_elixir/agent_runner/acpx.ex")
      |> Path.expand()

    assert File.exists?(acpx_runner_path)

    source = File.read!(acpx_runner_path)

    # Must use Port.open with {:spawn_executable, executable} where executable comes from CommandBuilder.
    assert source =~ "Port.open"
    assert source =~ "{:spawn_executable,"

    # Must not spawn any forbidden binary directly.
    for pattern <- @forbidden_patterns do
      refute Regex.match?(pattern, source),
             "AgentRunner.Acpx must not spawn forbidden binaries directly: #{inspect(pattern)}"
    end
  end

  test "custom agent command is passed to acpx --agent, not spawned directly" do
    command_builder_path =
      @production_lib_path
      |> Path.join("symphony_elixir/acpx/command_builder.ex")
      |> Path.expand()

    source = File.read!(command_builder_path)

    # custom_acpx_agent_command must produce a --agent argv entry.
    assert source =~ "\"--agent\""

    # Must not spawn custom command directly.
    refute source =~ ~r/System\.cmd\s*\(\s*[^)]*custom/,
           "Custom agent command must be passed to acpx --agent, not spawned directly"
  end
end
