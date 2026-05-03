defmodule SymphonyElixir.GitHub.CLI do
  @moduledoc """
  Thin argv-only wrapper around `gh`.

  Every operation goes through `System.cmd/3` (or a configurable runner for
  tests). Repository identifiers are validated by `SymphonyElixir.RepoId`
  before they are spliced into argv. We never use shell strings.

  Calls run inside a `Task` with a hard timeout so a hung or slow `gh`
  invocation cannot block the calling GenServer (orchestrator) or
  Phoenix request worker. The timeout is configurable via
  `:gh_cli_timeout_ms` and defaults to 15s.
  """

  alias SymphonyElixir.RepoId
  alias SymphonyElixir.Redaction

  require Logger

  @default_timeout_ms 15_000

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

  @doc false
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    Application.get_env(:symphony_elixir, :gh_cli_timeout_ms, @default_timeout_ms)
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

    case run_with_timeout(args, timeout_ms()) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        Logger.warning("gh #{summary(args)} exited #{status}: #{Redaction.redact(output)}")
        {:error, {:gh_exit, status, Redaction.redact(output)}}

      {:error, :timeout} ->
        Logger.warning("gh #{summary(args)} timed out after #{timeout_ms()}ms")
        {:error, :gh_timeout}

      {:error, {:runner_exit, reason}} ->
        Logger.warning("gh #{summary(args)} runner crashed: #{inspect(reason)}")
        {:error, {:gh_runner_exit, reason}}
    end
  end

  @doc """
  Run `gh` and stream `{:ok, output}` like `run/1`, but never raise on
  non-zero exit. Used by callers that need to interpret error text.
  """
  @spec run_lenient([String.t()]) :: {non_neg_integer(), String.t()}
  def run_lenient(args) when is_list(args) do
    Enum.each(args, &validate_arg!/1)

    case run_with_timeout(args, timeout_ms()) do
      {:ok, {output, status}} ->
        {status, Redaction.redact(output)}

      {:error, :timeout} ->
        Logger.warning("gh #{summary(args)} timed out after #{timeout_ms()}ms")
        # Mirror a non-zero exit so callers can branch on it.
        {124, Redaction.redact("gh timed out after #{timeout_ms()}ms")}

      {:error, {:runner_exit, reason}} ->
        Logger.warning("gh #{summary(args)} runner crashed: #{inspect(reason)}")
        # Distinguish from timeout via a different "exit code" so
        # callers that branch on it can tell apart a fast crash from
        # a deadline miss.
        {125, Redaction.redact("gh runner crashed: #{inspect(reason)}")}
    end
  end

  # Run `gh` inside a Task with a hard timeout. Task.shutdown unlinks
  # before killing, so a brutal_kill on timeout cannot crash the caller
  # GenServer (typical case: orchestrator handle_call). Synchronous
  # `System.cmd` provides no native timeout, hence this wrapper.
  defp run_with_timeout(args, deadline_ms) do
    runner_fun = runner()
    task = Task.async(fn -> runner_fun.(args, stderr_to_stdout: true) end)

    case Task.yield(task, deadline_ms) do
      # The runner returned cleanly inside the deadline.
      {:ok, result} ->
        {:ok, result}

      # The runner crashed BEFORE the deadline. Don't misreport this
      # as a timeout — bubble the exit reason so callers can tell a
      # genuine timeout (no result) apart from a fast crash.
      {:exit, reason} ->
        {:error, {:runner_exit, reason}}

      # No result yet → past the deadline. Brutal-kill the task and
      # report the timeout. `Task.shutdown(:brutal_kill)` returns
      # `nil` if the task was already gone, `{:ok, result}` if it
      # finished after `Task.yield/2` returned, or `{:exit, reason}`
      # if a crash raced the kill — handle each case explicitly.
      nil ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> {:ok, result}
          {:exit, reason} -> {:error, {:runner_exit, reason}}
          nil -> {:error, :timeout}
        end
    end
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
end
