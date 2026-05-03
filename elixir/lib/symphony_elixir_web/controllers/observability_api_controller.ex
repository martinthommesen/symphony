defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data and authenticated control.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Observability.{Control, Event, EventStore}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  require Logger

  @sse_heartbeat_interval_ms 20_000
  @sse_query_timeout_ms 2_000
  # Mailbox length thresholds for slow-consumer protection. PubSub
  # `send/2` to a wedged SSE pid never drops, so without backpressure a
  # slow client can OOM the BEAM. When the request mailbox grows past
  # `@sse_max_mailbox`, drain `:observability_event` messages down to
  # `@sse_drain_target` and surface the dropped count in the loop.
  @sse_max_mailbox 1_000
  @sse_drain_target 500
  # Hard lifetime cap so an SSE connection can never live indefinitely
  # even under sustained backpressure. 30 minutes is well above any
  # reasonable manual-watch session and short enough to bound memory in
  # pathological cases.
  @sse_max_lifetime_ms 30 * 60 * 1_000

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

    # SSE catch-up replays should not be silently capped on reconnect.
    # When the caller does not pass `limit`, replay every event matching
    # `since`/filters that the in-memory ring buffer still holds. The
    # ring is bounded by `observability.event_buffer_size`, so this is
    # already a finite upper bound — no need for an additional default.
    replay_filters =
      filters
      |> Map.put(:since, Map.get(params, "since"))
      |> Map.put(:limit, parse_limit(Map.get(params, "limit"), nil))

    case EventStore.subscribe() do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> :ok
    end

    # Treat `?since=` (empty) as no since filter; only replay when the
    # caller explicitly asked via `replay=1` or supplied a non-empty
    # `since` value.
    since = Map.get(params, "since")
    replay? = Map.get(params, "replay") == "1" or (is_binary(since) and since != "")

    conn =
      if replay? do
        replay_events(conn, replay_filters)
      else
        conn
      end

    case send_comment(conn, "connected") do
      {:ok, conn} ->
        deadline = System.monotonic_time(:millisecond) + @sse_max_lifetime_ms
        sse_loop(conn, filters, schedule_heartbeat(), 0, deadline)

      {:error, _reason} ->
        conn
    end
  end

  defp replay_events(conn, filters) do
    filters
    |> EventStore.query(EventStore, @sse_query_timeout_ms)
    |> Enum.reduce_while(conn, fn event, acc ->
      case send_event(acc, event) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, acc}
      end
    end)
  end

  # credo:disable-for-next-line
  defp sse_loop(conn, filters, heartbeat_ref, dropped, deadline_ms) do
    cond do
      System.monotonic_time(:millisecond) >= deadline_ms ->
        # Hard lifetime cap reached. Send a final summary frame so the
        # client knows to reconnect (carrying the last seen event id) and
        # bail out of the request process so no further messages
        # accumulate in its mailbox.
        Process.cancel_timer(heartbeat_ref)
        _ = send_comment(conn, "lifetime_exceeded:dropped=#{dropped}")
        conn

      mailbox_len() > @sse_max_mailbox ->
        drained = drain_observability_events(@sse_drain_target)

        Logger.warning("SSE consumer slow; mailbox dropped=#{drained} cumulative=#{dropped + drained}")

        sse_loop(conn, filters, heartbeat_ref, dropped + drained, deadline_ms)

      true ->
        receive do
          {:observability_event, %Event{} = event} ->
            if matches_filters?(event, filters) do
              case send_event(conn, event) do
                {:ok, conn} -> sse_loop(conn, filters, heartbeat_ref, dropped, deadline_ms)
                {:error, _reason} -> finish_sse(conn, heartbeat_ref)
              end
            else
              sse_loop(conn, filters, heartbeat_ref, dropped, deadline_ms)
            end

          :sse_heartbeat ->
            case send_comment(conn, "heartbeat") do
              {:ok, conn} -> sse_loop(conn, filters, schedule_heartbeat(), dropped, deadline_ms)
              {:error, _reason} -> finish_sse(conn, heartbeat_ref)
            end

          _other ->
            sse_loop(conn, filters, heartbeat_ref, dropped, deadline_ms)
        after
          30_000 ->
            case send_comment(conn, "idle:dropped=#{dropped}") do
              {:ok, conn} -> sse_loop(conn, filters, heartbeat_ref, dropped, deadline_ms)
              {:error, _reason} -> finish_sse(conn, heartbeat_ref)
            end
        end
    end
  end

  defp finish_sse(conn, heartbeat_ref) do
    # Cancel the still-pending heartbeat so the request process cannot
    # outlive the cleanup loop with a stray :sse_heartbeat message.
    Process.cancel_timer(heartbeat_ref)
    conn
  end

  defp mailbox_len do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} -> n
      _ -> 0
    end
  end

  defp drain_observability_events(target) do
    drain_loop(0, target)
  end

  defp drain_loop(drained, target) do
    if mailbox_len() > target do
      receive do
        {:observability_event, _event} -> drain_loop(drained + 1, target)
      after
        0 -> drained
      end
    else
      drained
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

      {:error, :timeout} ->
        error_response(conn, 503, "orchestrator_timeout", "Orchestrator did not respond in time")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  # Auth is enforced by `SymphonyElixirWeb.Plugs.RequireBearer` in the
  # router pipeline; by the time we reach this action, the request is
  # either authenticated or running on a loopback bind without a
  # configured token (see plug docstring).
  @spec control(Conn.t(), map()) :: Conn.t()
  # credo:disable-for-next-line
  def control(conn, params) do
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

      {:error, :pending_command_in_flight} ->
        error_response(
          conn,
          409,
          "pending_command_in_flight",
          "A previous command for this issue is still in flight"
        )

      {:error, :timeout} ->
        error_response(conn, 503, "orchestrator_timeout", "Orchestrator did not respond in time")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      {:error, :unknown_command} ->
        error_response(conn, 400, "unknown_command", "Unknown control command")

      {:error, reason} ->
        error_response(conn, 400, "control_error", inspect(reason))
    end
  end

  # credo:disable-for-next-line
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
