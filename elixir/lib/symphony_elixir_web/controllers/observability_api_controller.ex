defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data and authenticated control.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.Observability.{Control, Event, EventStore}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @sse_heartbeat_interval_ms 20_000

  # ---------------------------------------------------------------------------
  # Read endpoints
  # ---------------------------------------------------------------------------

  @spec health(Conn.t(), map()) :: Conn.t()
  def health(conn, _params) do
    json(conn, Presenter.health_payload(orchestrator()))
  end

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issues(Conn.t(), map()) :: Conn.t()
  def issues(conn, _params) do
    json(conn, Presenter.issues_list_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec events(Conn.t(), map()) :: Conn.t()
  def events(conn, params) do
    filters = %{
      type: Map.get(params, "type"),
      issue_identifier: Map.get(params, "issue_identifier"),
      issue_id: Map.get(params, "issue_id"),
      session_id: Map.get(params, "session_id"),
      severity: Map.get(params, "severity"),
      since: Map.get(params, "since"),
      limit: parse_limit(Map.get(params, "limit"))
    }

    json(conn, Presenter.events_payload(filters))
  end

  @spec analytics(Conn.t(), map()) :: Conn.t()
  def analytics(conn, _params) do
    json(conn, Presenter.analytics_payload(orchestrator(), snapshot_timeout_ms()))
  end

  # ---------------------------------------------------------------------------
  # SSE event stream
  # ---------------------------------------------------------------------------

  @spec event_stream(Conn.t(), map()) :: Conn.t()
  def event_stream(conn, params) do
    conn =
      conn
      |> Conn.put_resp_header("content-type", "text/event-stream")
      |> Conn.put_resp_header("cache-control", "no-cache")
      |> Conn.put_resp_header("connection", "keep-alive")
      |> Conn.put_resp_header("x-accel-buffering", "no")
      |> Conn.send_chunked(200)

    filters = %{
      type: Map.get(params, "type"),
      issue_identifier: Map.get(params, "issue_identifier"),
      issue_id: Map.get(params, "issue_id"),
      session_id: Map.get(params, "session_id"),
      severity: Map.get(params, "severity")
    }

    replay_filters =
      filters
      |> Map.put(:since, Map.get(params, "since"))
      |> Map.put(:limit, parse_limit(Map.get(params, "limit"), 100))

    case EventStore.subscribe() do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> :ok
    end

    conn =
      if Map.get(params, "replay") == "1" or Map.get(params, "since") do
        replay_events(conn, replay_filters)
      else
        conn
      end

    case send_comment(conn, "connected") do
      {:ok, conn} -> sse_loop(conn, filters, schedule_heartbeat(), 0)
      {:error, _reason} -> conn
    end
  end

  defp replay_events(conn, filters) do
    EventStore.query(filters)
    |> Enum.reduce_while(conn, fn event, acc ->
      case send_event(acc, event) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, acc}
      end
    end)
  end

  defp sse_loop(conn, filters, heartbeat_ref, dropped) do
    receive do
      {:observability_event, %Event{} = event} ->
        if matches_filters?(event, filters) do
          case send_event(conn, event) do
            {:ok, conn} -> sse_loop(conn, filters, heartbeat_ref, dropped)
            {:error, _reason} -> conn
          end
        else
          sse_loop(conn, filters, heartbeat_ref, dropped)
        end

      :sse_heartbeat ->
        case send_comment(conn, "heartbeat") do
          {:ok, conn} -> sse_loop(conn, filters, schedule_heartbeat(), dropped)
          {:error, _reason} -> conn
        end

      _other ->
        sse_loop(conn, filters, heartbeat_ref, dropped)
    after
      30_000 ->
        case send_comment(conn, "idle") do
          {:ok, conn} -> sse_loop(conn, filters, heartbeat_ref, dropped)
          {:error, _reason} -> conn
        end
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :sse_heartbeat, @sse_heartbeat_interval_ms)
  end

  defp send_event(conn, %Event{} = event) do
    payload = Event.to_payload(event)

    chunk =
      [
        "event: ",
        type_string(event.type),
        "\n",
        "id: ",
        event.id,
        "\n",
        "data: ",
        Jason.encode!(payload),
        "\n\n"
      ]
      |> IO.iodata_to_binary()

    Conn.chunk(conn, chunk)
  end

  defp matches_filters?(_event, filters) when filters == %{}, do: true

  defp matches_filters?(%Event{} = event, filters) do
    Enum.all?(filters, fn
      {_k, nil} -> true
      {_k, ""} -> true
      {:type, value} -> type_string(event.type) == to_string(value)
      {:issue_identifier, value} -> event.issue_identifier == value
      {:issue_id, value} -> event.issue_id == value
      {:session_id, value} -> event.session_id == value
      {:severity, value} -> Atom.to_string(event.severity) == to_string(value)
      _ -> true
    end)
  end

  # Returns `{:ok, conn}` on a successful chunk write or `{:error, reason}`
  # on transport failure. The caller must terminate the SSE loop on
  # `{:error, _}` so a disconnected client does not leave the request
  # process alive scheduling heartbeats forever.
  defp send_comment(conn, message) do
    Conn.chunk(conn, ":" <> message <> "\n\n")
  end

  defp type_string(value) when is_atom(value), do: Atom.to_string(value)
  defp type_string(value), do: to_string(value)

  defp parse_limit(value, default \\ 100)
  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> min(n, 1_000)
      _ -> default
    end
  end

  defp parse_limit(value, _default) when is_integer(value) and value > 0, do: min(value, 1_000)
  defp parse_limit(_, default), do: default

  # ---------------------------------------------------------------------------
  # Control endpoints
  # ---------------------------------------------------------------------------

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec control(Conn.t(), map()) :: Conn.t()
  def control(conn, params) do
    with :ok <- authorize(conn) do
      command = command_atom(params["command"] || List.last(conn.path_info))

      case Control.execute(command, params, orchestrator: orchestrator()) do
        {:ok, payload} ->
          json(conn, %{ok: true, command: command, payload: payload})

        {:error, :issue_not_found} ->
          error_response(conn, 404, "issue_not_found", "Issue not found")

        {:error, :issue_not_running} ->
          error_response(conn, 409, "issue_not_running", "Issue is not currently running")

        {:error, :not_dispatchable} ->
          error_response(conn, 409, "not_dispatchable", "Issue is not eligible for dispatch")

        {:error, :missing_issue_identifier} ->
          error_response(conn, 400, "missing_issue_identifier", "issue_identifier is required")

        {:error, :unsupported} ->
          error_response(conn, 409, "unsupported", "Tracker does not support this operation")

        {:error, :timeout} ->
          error_response(conn, 503, "orchestrator_timeout", "Orchestrator did not respond in time")

        {:error, :unavailable} ->
          error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

        {:error, :unknown_command} ->
          error_response(conn, 400, "unknown_command", "Unknown control command")

        {:error, reason} ->
          error_response(conn, 400, "control_error", inspect(reason))
      end
    else
      :read_only ->
        error_response(
          conn,
          403,
          "control_disabled",
          "Control endpoints are disabled (no token configured). Run scripts/setup-symphony-copilot.sh or set SYMPHONY_CONTROL_TOKEN."
        )

      {:error, :missing_token} ->
        error_response(conn, 401, "missing_token", "Authorization: Bearer <token> required")

      {:error, :invalid_token} ->
        error_response(conn, 401, "invalid_token", "Invalid bearer token")
    end
  end

  defp authorize(conn) do
    header =
      case Conn.get_req_header(conn, "authorization") do
        [value | _] -> value
        _ -> nil
      end

    Control.authenticate(Control.extract_bearer(header))
  end

  defp command_atom(value) when is_binary(value) do
    case String.downcase(value) do
      "refresh" -> :refresh
      "pause" -> :pause
      "resume" -> :resume
      "dispatch" -> :dispatch
      "stop" -> :stop
      "retry" -> :retry
      "block" -> :block
      "unblock" -> :unblock
      _ -> :unknown
    end
  end

  defp command_atom(_), do: :unknown

  # ---------------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------------

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    legacy_error(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    legacy_error(conn, 404, "not_found", "Route not found")
  end

  # Legacy endpoints use the original `{error: {code, message}}` envelope.
  # Existing API clients depend on this shape.
  defp legacy_error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  # New control endpoints use `{ok: false, error: ...}` per the cockpit spec.
  defp error_response(conn, status, code, message) do
    if control_endpoint?(conn) do
      conn
      |> put_status(status)
      |> json(%{ok: false, error: %{code: code, message: message}})
    else
      legacy_error(conn, status, code, message)
    end
  end

  defp control_endpoint?(%Conn{path_info: path_info}) do
    case path_info do
      ["api", "v1", "control" | _] -> true
      _ -> false
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
