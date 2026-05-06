defmodule SymphonyElixir.Git do
  @moduledoc """
  Small argv-only wrapper for Symphony-owned git commands.

  The wrapper preserves `System.cmd/3` return shape while emitting structured
  `git.ndjson` events for auditability.
  """

  alias SymphonyElixir.{Redaction, StructuredLogger}

  @spec cmd([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(args, opts \\ []) when is_list(args) do
    started_at = System.monotonic_time(:millisecond)
    {output, status} = System.cmd("git", args, opts)
    duration_ms = System.monotonic_time(:millisecond) - started_at
    log(args, opts, output, status, duration_ms)
    {output, status}
  end

  defp log(args, opts, output, status, duration_ms) do
    cwd = opts[:cd] || cwd_from_args(args)

    StructuredLogger.log_named("git", %{
      event_type: "git_command",
      severity: if(status == 0, do: "info", else: "error"),
      message: "git #{summary(args)} exited #{status}",
      workspace_path: cwd,
      payload: %{
        executable: "git",
        argv: Enum.map(args, &Redaction.redact/1),
        cwd: cwd,
        exit_code: status,
        duration_ms: duration_ms,
        output: Redaction.redact(output)
      }
    })
  rescue
    _ -> :ok
  end

  defp cwd_from_args(["-C", cwd | _]), do: cwd
  defp cwd_from_args(_args), do: nil

  defp summary(args) do
    args
    |> Enum.take(4)
    |> Enum.join(" ")
  end
end
