defmodule SymphonyElixir.Observability.Analytics do
  @moduledoc """
  Aggregate metrics over the in-memory event ring buffer and orchestrator
  snapshot. Pure with respect to its inputs — call sites are expected to
  pass the events they want considered. The HTTP controller wires up the
  default sources.
  """

  alias SymphonyElixir.Observability.Event

  @type metrics :: map()

  @doc """
  Compute aggregate metrics from `events` and `snapshot`.

  `snapshot` may be the orchestrator snapshot map or `nil`.
  """
  @spec compute([Event.t()], map() | nil) :: metrics()
  def compute(events, snapshot \\ nil) when is_list(events) do
    grouped = Enum.group_by(events, &type_label/1)
    runtimes = runtime_seconds(events)
    finalizers = grouped["finalizer_completed"] || []
    failed = grouped["agent_failed"] || []
    timed_out = grouped["agent_timed_out"] || []
    stalled = grouped["agent_stalled"] || []
    pr_opened = grouped["pr_opened"] || []
    retry_scheduled = grouped["retry_scheduled"] || []
    issue_dispatched = grouped["issue_dispatched"] || []

    snapshot_running = (snapshot && Map.get(snapshot, :running)) || []
    snapshot_retrying = (snapshot && Map.get(snapshot, :retrying)) || []
    max_concurrent = (snapshot && Map.get(snapshot, :max_concurrent_agents)) || 0
    codex_totals = (snapshot && Map.get(snapshot, :codex_totals)) || %{}

    %{
      generated_at: iso_now(),
      source: %{
        mode: source_mode(events),
        history_loaded: events != [],
        event_count: length(events),
        window_seconds: window_seconds(events)
      },
      metrics: %{
        active_agents: length(snapshot_running),
        retrying_agents: length(snapshot_retrying),
        agent_capacity: %{
          max: max_concurrent,
          running: length(snapshot_running),
          available: max(max_concurrent - length(snapshot_running), 0),
          utilization: utilization(snapshot_running, max_concurrent)
        },
        throughput: %{
          dispatched: length(issue_dispatched),
          finalizer_completed: length(finalizers),
          pr_opened: length(pr_opened)
        },
        failures: %{
          agent_failed: length(failed),
          agent_timed_out: length(timed_out),
          agent_stalled: length(stalled),
          retry_scheduled: length(retry_scheduled),
          failure_reasons: failure_reasons(failed ++ timed_out ++ stalled)
        },
        runtime: %{
          completed_count: length(runtimes),
          average_seconds: average(runtimes),
          p50_seconds: percentile(runtimes, 50),
          p95_seconds: percentile(runtimes, 95)
        },
        tokens: %{
          input_tokens: Map.get(codex_totals, :input_tokens, 0),
          output_tokens: Map.get(codex_totals, :output_tokens, 0),
          total_tokens: Map.get(codex_totals, :total_tokens, 0),
          seconds_running: Map.get(codex_totals, :seconds_running, 0),
          tokens_per_second: tokens_per_second(codex_totals)
        },
        worker_utilization: worker_utilization(snapshot_running),
        top_token_consumers: top_token_consumers(snapshot_running)
      }
    }
  end

  defp type_label(%Event{type: t}) when is_atom(t), do: Atom.to_string(t)
  defp type_label(%Event{type: t}) when is_binary(t), do: t
  defp type_label(%Event{type: t}), do: to_string(t)

  defp runtime_seconds(events) do
    events
    |> Enum.flat_map(fn
      %Event{type: type, data: data} when type in [:finalizer_completed, "finalizer_completed"] ->
        case Map.get(data, "runtime_seconds") || Map.get(data, :runtime_seconds) do
          n when is_integer(n) -> [n]
          n when is_float(n) -> [trunc(n)]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp failure_reasons(events) do
    events
    |> Enum.frequencies_by(fn %Event{message: msg, data: data} ->
      Map.get(data, "reason") || Map.get(data, :reason) || msg || "unknown"
    end)
    |> Enum.map(fn {reason, count} -> %{reason: reason, count: count} end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(10)
  end

  defp utilization([], 0), do: 0.0
  defp utilization(_running, 0), do: 0.0

  defp utilization(running, max) when is_integer(max) and max > 0 do
    Float.round(length(running) / max, 3)
  end

  defp average([]), do: 0
  defp average(values), do: Float.round(Enum.sum(values) / length(values), 2)

  defp percentile([], _p), do: 0

  defp percentile(values, p) when is_list(values) and is_integer(p) do
    sorted = Enum.sort(values)
    index = max(round(length(sorted) * p / 100) - 1, 0)
    Enum.at(sorted, min(index, length(sorted) - 1))
  end

  defp tokens_per_second(%{seconds_running: 0}), do: 0
  defp tokens_per_second(%{seconds_running: nil}), do: 0

  defp tokens_per_second(%{total_tokens: total, seconds_running: seconds})
       when is_integer(total) and is_integer(seconds) and seconds > 0 do
    Float.round(total / seconds, 2)
  end

  defp tokens_per_second(_), do: 0

  defp worker_utilization(running) do
    running
    |> Enum.frequencies_by(fn entry -> Map.get(entry, :worker_host) || "local" end)
    |> Enum.map(fn {host, count} -> %{worker_host: host, running: count} end)
  end

  defp top_token_consumers(running) do
    running
    |> Enum.map(fn entry ->
      tokens = total_tokens_from_entry(entry)

      %{
        issue_identifier: Map.get(entry, :identifier),
        issue_id: Map.get(entry, :issue_id),
        total_tokens: tokens
      }
    end)
    |> Enum.sort_by(& &1.total_tokens, :desc)
    |> Enum.take(5)
  end

  defp total_tokens_from_entry(entry) do
    Map.get(entry, :codex_total_tokens) || Map.get(entry, :total_tokens) || 0
  end

  defp source_mode([]), do: "snapshot_only"
  defp source_mode(_events), do: "event_store"

  defp window_seconds([]), do: 0

  defp window_seconds(events) do
    timestamps =
      events
      |> Enum.map(fn %Event{timestamp: ts} -> ts end)
      |> Enum.filter(&match?(%DateTime{}, &1))

    case timestamps do
      [] ->
        0

      [_] ->
        0

      _ ->
        first = Enum.min_by(timestamps, &DateTime.to_unix/1)
        last = Enum.max_by(timestamps, &DateTime.to_unix/1)
        DateTime.diff(last, first, :second)
    end
  end

  defp iso_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
