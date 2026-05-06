defmodule SymphonyElixir.GitHub.CLI do
  @moduledoc """
  Thin argv-only wrapper around `gh`.

  Every operation goes through `System.cmd/3` (or a configurable runner for
  tests). Repository identifiers are validated by `SymphonyElixir.RepoId`
  before they are spliced into argv. We never use shell strings.
  """

  alias SymphonyElixir.{Redaction, StructuredLogger}
  alias SymphonyElixir.RepoId

  require Logger

  @type runner :: ([String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec default_runner() :: runner()
  def default_runner do
    fn args, opts ->
      System.cmd("gh", args, opts)
    end
  end

  @spec runner() :: runner()
  def runner do
    Application.get_env(:symphony_elixir, :gh_runner, default_runner())
  end

  @doc """
  Run `gh api <path>` with optional flags and parse the JSON response.

  `args` is a list of additional argv entries (e.g. ["-X", "POST", "-f",
  "title=...", "--paginate"]). The function does not interpolate the
  caller's data into a shell string.
  """
  @spec api(String.t(), [String.t()]) :: {:ok, term()} | {:error, term()}
  def api(path, args \\ []) when is_binary(path) and is_list(args) do
    case run(["api", path] ++ args) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:gh_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run an arbitrary `gh` argv. Returns `{:ok, stdout}` on exit code 0 and
  `{:error, {:gh_exit, code, redacted_output}}` otherwise.
  """
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(args) when is_list(args) do
    Enum.each(args, &validate_arg!/1)

    started_at = System.monotonic_time(:millisecond)
    {output, status} = runner().(args, stderr_to_stdout: true)
    duration_ms = System.monotonic_time(:millisecond) - started_at
    log_github_command(args, status, output, duration_ms)

    case status do
      0 ->
        {:ok, output}

      _ ->
        Logger.warning("gh #{summary(args)} exited #{status}: #{Redaction.redact(output)}")
        {:error, {:gh_exit, status, Redaction.redact(output)}}
    end
  end

  @doc """
  Run `gh` and stream `{:ok, output}` like `run/1`, but never raise on
  non-zero exit. Used by callers that need to interpret error text.
  """
  @spec run_lenient([String.t()]) :: {non_neg_integer(), String.t()}
  def run_lenient(args) when is_list(args) do
    Enum.each(args, &validate_arg!/1)

    started_at = System.monotonic_time(:millisecond)
    {output, status} = runner().(args, stderr_to_stdout: true)
    duration_ms = System.monotonic_time(:millisecond) - started_at
    log_github_command(args, status, output, duration_ms)

    {status, Redaction.redact(output)}
  end

  @doc """
  Validate an `owner/repo` string and return it unchanged.
  Raises if the input is malformed.
  """
  @spec assert_repo!(String.t()) :: String.t()
  def assert_repo!(repo) do
    case RepoId.validate(repo) do
      {:ok, value} -> value
      {:error, _} -> raise ArgumentError, "invalid repo identifier: #{inspect(repo)}"
    end
  end

  defp validate_arg!(arg) when is_binary(arg) do
    if String.contains?(arg, [<<0>>]) do
      raise ArgumentError, "argv argument contains NUL byte"
    end

    arg
  end

  defp validate_arg!(arg), do: raise(ArgumentError, "argv argument is not a string: #{inspect(arg)}")

  defp summary(args) do
    args
    |> Enum.take(3)
    |> Enum.join(" ")
  end

  defp log_github_command(args, status, output, duration_ms) do
    StructuredLogger.log_named("github", %{
      event_type: "github_cli_command",
      severity: if(status == 0, do: "info", else: "error"),
      message: "gh #{summary(args)} exited #{status}",
      payload: %{
        executable: "gh",
        argv: Enum.map(args, &Redaction.redact/1),
        exit_code: status,
        duration_ms: duration_ms,
        output: Redaction.redact(output)
      }
    })
  rescue
    _ -> :ok
  end
end
