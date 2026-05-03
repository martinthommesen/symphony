# credo:disable-for-this-file
defmodule SymphonyElixir.Observability.EventStore do
  @moduledoc """
  In-memory ring-buffer store for redacted observability events with optional
  append-only JSONL persistence and PubSub broadcast for SSE delivery.

  Failure modes are deliberately tolerant: a JSONL write error logs a warning
  and continues, and malformed JSONL lines on startup load are skipped. The
  store never crashes the orchestrator pipeline.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Observability.Event

  @pubsub SymphonyElixir.PubSub
  @topic "observability:events"

  defmodule State do
    @moduledoc false

    @enforce_keys [:buffer_size]
    defstruct [
      :buffer_size,
      :jsonl_enabled,
      :jsonl_path,
      events: :queue.new(),
      length: 0,
      total_appended: 0,
      jsonl_failures: 0
    ]
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, false} ->
        # Anonymous instance (used by tests that want to avoid registering
        # a global name). Caller is expected to keep the pid.
        GenServer.start_link(__MODULE__, opts)

      {:ok, name} ->
        GenServer.start_link(__MODULE__, opts, name: name)

      :error ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc """
  Build a redacted event from `attrs` and append it to the store.
  """
  @spec emit(map() | keyword(), GenServer.server()) :: Event.t()
  def emit(attrs, server \\ __MODULE__) do
    event = Event.new(attrs)
    cast_or_drop(server, {:append, event})
    event
  end

  @doc """
  Append an already-built event (it will be redacted again as defense in depth).
  """
  @spec append(Event.t(), GenServer.server()) :: Event.t()
  def append(%Event{} = event, server \\ __MODULE__) do
    redacted = Event.new(Map.from_struct(event))
    cast_or_drop(server, {:append, redacted})
    redacted
  end

  @doc """
  Subscribe the calling process to live event broadcasts. Messages take the
  shape `{:observability_event, %Event{}}`.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    case GenServer.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.subscribe(@pubsub, @topic)
      _ -> :ok
    end
  end

  @spec unsubscribe() :: :ok | {:error, term()}
  def unsubscribe do
    case GenServer.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.unsubscribe(@pubsub, @topic)
      _ -> :ok
    end
  end

  @doc """
  Return the most recent events optionally filtered by `:since` (ISO 8601 or
  event id), `:type`, `:issue_identifier`, `:session_id`, and `:limit`.

  `timeout` bounds the underlying `GenServer.call`. SSE replay paths pass
  a short timeout so a reconnect storm cannot stack 5s default-timeout
  queries on the EventStore mailbox; on timeout the query returns `[]`.
  """
  @spec query(map() | keyword(), GenServer.server(), timeout()) :: [Event.t()]
  def query(filters \\ %{}, server \\ __MODULE__, timeout \\ 5_000)

  @spec query(map() | keyword(), GenServer.server(), timeout()) :: [Event.t()]
  def query(filters, server, timeout) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, {:query, normalize_filters(filters)}, timeout)
        catch
          :exit, {:timeout, _} -> []
          :exit, _ -> []
        end

      _ ->
        []
    end
  end

  @doc """
  Return store stats. Useful for `/api/v1/health` and analytics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(pid, :stats)
      _ -> %{available: false, length: 0, total_appended: 0}
    end
  end

  @doc """
  Returns the configured PubSub topic. Exposed for tests and SSE plumbing.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    {buffer_size, jsonl_enabled, jsonl_path} = resolve_settings(opts)

    state = %State{
      buffer_size: buffer_size,
      jsonl_enabled: jsonl_enabled,
      jsonl_path: jsonl_path
    }

    state = maybe_load_history(state)

    {:ok, state}
  end

  @impl true
  def handle_cast({:append, %Event{} = event}, state) do
    state =
      state
      |> push(event)
      |> maybe_persist(event)

    broadcast(event)

    {:noreply, state}
  end

  @impl true
  def handle_call({:query, filters}, _from, state) do
    {:reply, do_query(state, filters), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       available: true,
       length: state.length,
       total_appended: state.total_appended,
       jsonl_failures: state.jsonl_failures,
       jsonl_enabled: state.jsonl_enabled,
       jsonl_path: state.jsonl_path,
       buffer_size: state.buffer_size
     }, state}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp cast_or_drop(server, message) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.cast(pid, message)
      _ -> :ok
    end
  end

  defp resolve_settings(opts) do
    obs =
      try do
        Config.settings!().observability
      rescue
        _ -> %{}
      end

    buffer_size = Keyword.get(opts, :buffer_size) || Map.get(obs, :event_buffer_size) || 5_000

    jsonl_enabled =
      case Keyword.fetch(opts, :jsonl_enabled) do
        {:ok, value} -> value
        :error -> Map.get(obs, :jsonl_enabled, true)
      end

    jsonl_path =
      Keyword.get(opts, :jsonl_path) ||
        Map.get(obs, :jsonl_path) || ".symphony/logs/events.jsonl"

    {buffer_size, jsonl_enabled, jsonl_path}
  end

  defp push(state, event) do
    queue = :queue.in(event, state.events)

    {queue, length} =
      if state.length + 1 > state.buffer_size do
        {{_dropped, q}, _} = pop_one(queue)
        {q, state.buffer_size}
      else
        {queue, state.length + 1}
      end

    %{state | events: queue, length: length, total_appended: state.total_appended + 1}
  end

  defp pop_one(queue) do
    case :queue.out(queue) do
      {{:value, ev}, q} -> {{ev, q}, true}
      {:empty, q} -> {{nil, q}, false}
    end
  end

  defp maybe_persist(%State{jsonl_enabled: false} = state, _event), do: state

  defp maybe_persist(%State{jsonl_path: path} = state, %Event{} = event)
       when is_binary(path) and path != "" do
    case persist_line(path, event) do
      :ok -> state
      {:error, _reason} -> %{state | jsonl_failures: state.jsonl_failures + 1}
    end
  end

  defp maybe_persist(state, _event), do: state

  defp persist_line(path, event) do
    with :ok <- ensure_parent_dir(path),
         {:ok, json} <- safe_encode(event),
         :ok <- File.write(path, json <> "\n", [:append]) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("EventStore JSONL write failed (#{inspect(reason)}); continuing")
        {:error, reason}
    end
  end

  defp safe_encode(event) do
    case Jason.encode(Event.to_payload(event)) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_error, reason}}
    end
  end

  defp ensure_parent_dir(path) do
    parent = Path.dirname(path)

    case parent do
      "" -> :ok
      "." -> :ok
      _ -> File.mkdir_p(parent)
    end
  rescue
    error -> {:error, error}
  end

  defp broadcast(%Event{} = event) do
    case GenServer.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:observability_event, event})

      _ ->
        :ok
    end
  end

  defp maybe_load_history(%State{jsonl_enabled: false} = state), do: state

  defp maybe_load_history(%State{jsonl_path: path, buffer_size: size} = state)
       when is_binary(path) and path != "" do
    # credo:disable-for-next-line
    cond do
      not File.exists?(path) ->
        state

      true ->
        case load_recent_lines(path, size) do
          {:ok, events} ->
            Enum.reduce(events, state, fn event, acc ->
              # Don't re-persist on startup load; just push into ring.
              %{
                acc
                | events: :queue.in(event, acc.events),
                  length: min(acc.length + 1, acc.buffer_size),
                  total_appended: acc.total_appended + 1
              }
              |> trim_to_buffer_size()
            end)

          {:error, reason} ->
            Logger.warning("EventStore JSONL history load failed (#{inspect(reason)}); starting empty")

            state
        end
    end
  rescue
    error ->
      Logger.warning("EventStore JSONL history load crashed (#{inspect(error)}); starting empty")
      state
  end

  defp maybe_load_history(state), do: state

  defp trim_to_buffer_size(%State{length: length, buffer_size: size} = state)
       when length > size do
    {{_dropped, q}, _} = pop_one(state.events)

    %{state | events: q, length: length - 1}
    |> trim_to_buffer_size()
  end

  defp trim_to_buffer_size(state), do: state

  defp load_recent_lines(path, size) when is_binary(path) and is_integer(size) and size > 0 do
    # Stream the JSONL file line-by-line and keep only the last `size`
    # items in a bounded queue. This is O(size) memory regardless of
    # total file size — long-running deployments can accumulate very
    # large logs, and the previous `File.read/1 + Enum.take(-size)` form
    # held the entire file in memory at startup.
    # credo:disable-for-next-line
    try do
      tail_queue =
        path
        |> File.stream!([:read], :line)
        |> Enum.reduce(:queue.new(), fn line, queue ->
          queue = :queue.in(line, queue)

          if :queue.len(queue) > size do
            {_, q} = :queue.out(queue)
            q
          else
            queue
          end
        end)

      events =
        tail_queue
        |> :queue.to_list()
        |> Enum.flat_map(&decode_jsonl_line/1)

      {:ok, events}
    rescue
      error -> {:error, error}
    end
  end

  defp load_recent_lines(_path, _size), do: {:ok, []}

  defp decode_jsonl_line(line) when is_binary(line) do
    # credo:disable-for-next-line
    case String.trim_trailing(line, "\n") do
      "" ->
        []

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, payload} ->
            case payload_to_event(payload) do
              %Event{} = event -> [event]
              _ -> []
            end

          {:error, reason} ->
            Logger.debug("Skipping malformed JSONL line (#{inspect(reason)})")
            []
        end
    end
  end

  defp decode_jsonl_line(_line), do: []

  defp payload_to_event(payload) when is_map(payload) do
    timestamp =
      case payload["timestamp"] do
        ts when is_binary(ts) ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        _ ->
          nil
      end

    Event.new(%{
      id: payload["id"],
      type: payload["type"],
      severity: payload["severity"],
      timestamp: timestamp,
      issue_id: payload["issue_id"],
      issue_identifier: payload["issue_identifier"],
      issue_number: payload["issue_number"],
      session_id: payload["session_id"],
      worker_host: payload["worker_host"],
      workspace_path: payload["workspace_path"],
      message: payload["message"],
      data: payload["data"] || %{}
    })
  rescue
    _ -> nil
  end

  defp payload_to_event(_), do: nil

  defp do_query(state, filters) do
    # `apply_since/2` runs FIRST so its event-id high-water mark always
    # finds the marker in the full chronological stream. If we filtered
    # by type/severity/issue_identifier before applying `since`, an
    # event-id `since` whose marker doesn't match the other filters
    # would get removed early, the split would fail, and the call would
    # return the entire filtered list — duplicating events on SSE
    # resume.
    state.events
    |> :queue.to_list()
    |> apply_since(filters)
    |> Enum.filter(&matches?(&1, filters))
    |> apply_limit(filters)
  end

  defp matches?(%Event{} = event, filters) do
    Enum.all?(filters, fn
      {:type, value} -> normalize_type_filter(event.type) == normalize_type_filter(value)
      {:issue_identifier, value} -> event.issue_identifier == value
      {:issue_id, value} -> event.issue_id == value
      {:session_id, value} -> event.session_id == value
      {:severity, value} -> Atom.to_string(event.severity) == to_string(value)
      _ -> true
    end)
  end

  defp normalize_type_filter(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_type_filter(value), do: to_string(value)

  defp apply_since(events, %{since: since}) when is_binary(since) and since != "" do
    case DateTime.from_iso8601(since) do
      {:ok, threshold, _offset} ->
        Enum.filter(events, fn %Event{timestamp: ts} ->
          DateTime.compare(ts, threshold) != :lt
        end)

      _ ->
        # Treat as event id high-water mark.
        # credo:disable-for-next-line
        case Enum.split_while(events, fn %Event{id: id} -> id != since end) do
          # Found the id; replay only what came after it.
          {_before, [_match | rest]} ->
            rest

          # `since` was given but the id is no longer in the ring buffer
          # (eviction or restart). Returning the entire filtered list
          # would re-flood reconnecting clients with already-seen events
          # and inflate their dedupe sets. Return [] instead so the
          # client falls back to its existing state via `/api/v1/events`.
          _ ->
            []
        end
    end
  end

  defp apply_since(events, _filters), do: events

  defp apply_limit(events, %{limit: limit}) when is_integer(limit) and limit > 0 do
    events
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp apply_limit(events, _filters), do: events

  defp normalize_filters(filters) when is_list(filters), do: normalize_filters(Map.new(filters))

  defp normalize_filters(filters) when is_map(filters) do
    # Whitelist of keys the store actually understands. We allow callers
    # to pass either atom or string keys but never mint new atoms — also
    # never drop *all* filters because of one bad key (which the previous
    # `String.to_existing_atom/1 + rescue ArgumentError -> %{}` did).
    Enum.reduce(filters, %{}, fn entry, acc ->
      case normalize_filter_entry(entry) do
        {key, value} -> Map.put(acc, key, value)
        :skip -> acc
      end
    end)
  end

  @known_filter_keys [:type, :issue_identifier, :issue_id, :session_id, :severity, :since, :limit]
  @known_filter_strings ["type", "issue_identifier", "issue_id", "session_id", "severity", "since", "limit"]

  defp normalize_filter_entry({_k, nil}), do: :skip
  defp normalize_filter_entry({_k, ""}), do: :skip

  defp normalize_filter_entry({k, v}) when is_atom(k) do
    if k in @known_filter_keys, do: {k, v}, else: :skip
  end

  defp normalize_filter_entry({k, v}) when is_binary(k) do
    if k in @known_filter_strings,
      do: {String.to_existing_atom(k), v},
      else: :skip
  end

  defp normalize_filter_entry(_), do: :skip
end
