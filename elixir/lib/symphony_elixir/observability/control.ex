# credo:disable-for-this-file
defmodule SymphonyElixir.Observability.Control do
  @moduledoc """
  Authenticated control surface for the operations cockpit.

  Resolves the bearer token (env var > token file), authenticates incoming
  HTTP requests, and dispatches commands to the orchestrator and tracker.
  All accepted/rejected/completed commands emit observability events.
  """

  import Bitwise, only: [bor: 2, bxor: 2]

  alias SymphonyElixir.{Config, Observability, Orchestrator, Tracker}

  @env_var "SYMPHONY_CONTROL_TOKEN"

  @type auth_result ::
          :ok
          | :read_only
          | {:error, :missing_token | :invalid_token}

  @doc """
  Returns the configured control token, or `nil` if no token is configured
  (read-only mode).
  """
  @spec configured_token() :: String.t() | nil
  # credo:disable-for-next-line
  def configured_token do
    case env_token() do
      token when is_binary(token) ->
        token

      nil ->
        case token_file_path() do
          nil ->
            nil

          path ->
            case File.read(path) do
              {:ok, contents} -> nilify_blank(String.trim(contents))
              _ -> nil
            end
        end
    end
  end

  defp env_token do
    case System.get_env(@env_var) do
      value when is_binary(value) -> nilify_blank(String.trim(value))
      _ -> nil
    end
  end

  # A whitespace-only env var or token file would otherwise mark control
  # as "enabled" with an empty shared secret (`Authorization: Bearer `).
  # Treat blanks as if no token were configured.
  defp nilify_blank(""), do: nil
  defp nilify_blank(value), do: value

  @doc """
  Returns `true` when control is enabled (a token is configured).
  """
  @spec control_enabled?() :: boolean()
  def control_enabled?, do: not is_nil(configured_token())

  @doc """
  Returns the file the control token is looked up from, or `nil` when no
  observability config is loaded (e.g., during early boot).
  """
  @spec token_file_path() :: String.t() | nil
  def token_file_path do
    # credo:disable-for-next-line
    try do
      case Config.settings!().observability.control_token_file do
        path when is_binary(path) and byte_size(path) > 0 -> path
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  @doc """
  Authenticate a presented bearer token against the configured token.

  Returns:
    * `:ok` on a match
    * `:read_only` when no token is configured (control disabled)
    * `{:error, :missing_token}` when caller did not present a token
    * `{:error, :invalid_token}` when the presented token is wrong

  Comparison is constant-time.
  """
  @spec authenticate(String.t() | nil) :: auth_result()
  def authenticate(presented) do
    case configured_token() do
      nil ->
        :read_only

      configured when is_binary(configured) ->
        # Always route through `secure_equal?/2` — including for matching
        # tokens — so the comparison time does not depend on how many
        # leading bytes are correct. A `^configured -> :ok` pin would
        # short-circuit and reintroduce a timing side-channel between
        # correct and almost-correct tokens.
        cond do
          is_nil(presented) -> {:error, :missing_token}
          is_binary(presented) and secure_equal?(configured, presented) -> :ok
          true -> {:error, :invalid_token}
        end
    end
  end

  @doc """
  Extract the bearer token from a header value of the shape
  "Bearer <token>" (case insensitive). Returns `nil` if absent or malformed.
  """
  @spec extract_bearer(String.t() | nil) :: String.t() | nil
  def extract_bearer(header) when is_binary(header) do
    case Regex.run(~r/^\s*[Bb]earer\s+(\S+)\s*$/, header) do
      [_, token] -> token
      _ -> nil
    end
  end

  def extract_bearer(_), do: nil

  @doc """
  Returns `true` when the configured server host is a loopback address
  (`127.0.0.1`, `localhost`, or `::1`), `false` otherwise. Defaults to
  `true` if the configuration cannot be loaded.

  Note: mutating endpoints **always** require a token in this
  implementation regardless of host. This helper exists so callers can
  decide whether to allow *read* endpoints to skip auth on loopback.
  """
  @spec loopback_only?() :: boolean()
  def loopback_only? do
    # credo:disable-for-next-line
    try do
      case Config.settings!().server.host do
        host when is_binary(host) ->
          host == "127.0.0.1" or host == "localhost" or host == "::1"

        _ ->
          true
      end
    rescue
      _ -> true
    end
  end

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch a command. Emits `control_command_*` audit events around the call.

  Pass `:orchestrator` in `opts` to target a non-default orchestrator
  process (used when the Phoenix endpoint is started with a custom
  orchestrator name — see `SymphonyElixirWeb.Endpoint.config(:orchestrator)`).
  """
  @spec execute(atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(command, params, opts \\ []) when is_atom(command) and is_map(params) do
    Observability.emit(:control_command_requested, %{
      message: "control command requested",
      data: %{command: Atom.to_string(command), params: redact_params(params)}
    })

    result = do_execute(command, params, opts)

    case result do
      {:ok, payload} ->
        Observability.emit(:control_command_completed, %{
          message: "control command completed",
          data: %{command: Atom.to_string(command), payload: payload}
        })

        result

      {:error, reason} ->
        Observability.emit_warning(:control_command_rejected, %{
          message: "control command rejected: #{inspect(reason)}",
          data: %{command: Atom.to_string(command), reason: inspect(reason)}
        })

        result
    end
  end

  defp do_execute(:refresh, _params, opts) do
    case Orchestrator.request_refresh(orchestrator(opts)) do
      :unavailable ->
        {:error, :unavailable}

      :timeout ->
        {:error, :timeout}

      payload when is_map(payload) ->
        {:ok,
         payload
         |> Map.update(:requested_at, nil, &maybe_iso/1)}
    end
  end

  defp do_execute(:pause, _params, opts), do: Orchestrator.pause_polling(orchestrator(opts))
  defp do_execute(:resume, _params, opts), do: Orchestrator.resume_polling(orchestrator(opts))

  defp do_execute(:dispatch, %{"issue_identifier" => id}, opts) when is_binary(id) and id != "" do
    Orchestrator.request_dispatch(orchestrator(opts), id)
  end

  defp do_execute(:dispatch, _, _opts), do: {:error, :missing_issue_identifier}

  defp do_execute(:stop, %{"issue_identifier" => id}, opts) when is_binary(id) and id != "" do
    Orchestrator.stop_issue(orchestrator(opts), id)
  end

  defp do_execute(:stop, _, _opts), do: {:error, :missing_issue_identifier}

  defp do_execute(:retry, %{"issue_identifier" => id}, opts) when is_binary(id) and id != "" do
    Orchestrator.retry_issue(orchestrator(opts), id)
  end

  defp do_execute(:retry, _, _opts), do: {:error, :missing_issue_identifier}

  defp do_execute(:block, %{"issue_identifier" => id}, _opts) when is_binary(id) and id != "" do
    case Tracker.block_issue(id) do
      :ok -> {:ok, %{status: "blocked", issue_identifier: id}}
      other -> other
    end
  end

  defp do_execute(:block, _, _opts), do: {:error, :missing_issue_identifier}

  defp do_execute(:unblock, %{"issue_identifier" => id}, _opts) when is_binary(id) and id != "" do
    case Tracker.unblock_issue(id) do
      :ok -> {:ok, %{status: "unblocked", issue_identifier: id}}
      other -> other
    end
  end

  defp do_execute(:unblock, _, _opts), do: {:error, :missing_issue_identifier}

  defp do_execute(_command, _params, _opts), do: {:error, :unknown_command}

  defp orchestrator(opts), do: Keyword.get(opts, :orchestrator, Orchestrator)

  defp maybe_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_iso(value), do: value

  defp redact_params(params) when is_map(params) do
    # Tokens never appear in params, but be defensive: skip "token" keys.
    params
    |> Enum.reject(fn {k, _v} -> k in ["token", "Authorization", :token] end)
    |> Map.new()
  end

  # Plug.Crypto.secure_compare/2 is provided by `:plug_crypto`, which
  # Phoenix already pulls into the dep tree. We fall back to a pure-Elixir
  # constant-time comparison for non-Phoenix test contexts.
  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    if Code.ensure_loaded?(Plug.Crypto) and function_exported?(Plug.Crypto, :secure_compare, 2) do
      Plug.Crypto.secure_compare(a, b)
    else
      constant_time_equal(a, b, byte_size(a), 0)
    end
  end

  defp secure_equal?(_a, _b), do: false

  defp constant_time_equal(_a, _b, 0, acc), do: acc == 0

  defp constant_time_equal(a, b, n, acc) do
    <<ax, ar::binary>> = a
    <<bx, br::binary>> = b
    constant_time_equal(ar, br, n - 1, bor(acc, bxor(ax, bx)))
  end
end
