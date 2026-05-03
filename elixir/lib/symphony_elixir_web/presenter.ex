defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Tracker}
  alias SymphonyElixir.Linear.Issue, as: TrackerIssue
  alias SymphonyElixir.Observability.{Analytics, Control, Event, EventStore}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = iso_now()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.map(snapshot.running, &running_entry_payload/1)
        retrying = Enum.map(snapshot.retrying, &retry_entry_payload/1)
        polling = expanded_polling(snapshot)
        capacity = expanded_capacity(snapshot)
        recent_events = recent_events_payload()

        %{
          generated_at: generated_at,
          status: orchestrator_status(polling),
          counts: %{
            running: length(running),
            retrying: length(retrying),
            review: count_state(running, "review"),
            failed: count_state(running, "failed"),
            blocked: count_state(running, "blocked")
          },
          running: running,
          retrying: retrying,
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          polling: polling,
          agent_capacity: capacity,
          tokens: %{
            input_tokens: get_in(snapshot, [:codex_totals, :input_tokens]) || 0,
            output_tokens: get_in(snapshot, [:codex_totals, :output_tokens]) || 0,
            total_tokens: get_in(snapshot, [:codex_totals, :total_tokens]) || 0,
            tokens_per_second: tokens_per_second_from_snapshot(snapshot)
          },
          recent_events: recent_events
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec health_payload(GenServer.name()) :: map()
  def health_payload(orchestrator) do
    settings =
      try do
        Config.settings!()
      rescue
        _ -> nil
      end

    repo = settings && Map.get(settings.tracker, :repo)
    host = settings && Map.get(settings.server, :host)
    port = (settings && Map.get(settings.server, :port)) || Config.server_port() || 0

    control_enabled = Control.control_enabled?()

    # `orchestrator` may be an atom, a pid, or a `{name, node}` tuple
    # (when the endpoint is configured for tests). `Process.whereis/1`
    # raises on the latter two, so route through `GenServer.whereis/1`.
    orchestrator_alive = is_pid(GenServer.whereis(orchestrator))

    %{
      status: if(orchestrator_alive, do: "ok", else: "degraded"),
      version: Application.spec(:symphony_elixir, :vsn) |> to_string(),
      repo: repo,
      server: %{host: host || "127.0.0.1", port: port},
      capabilities: %{
        control: control_enabled,
        events_stream: true,
        analytics: true,
        read_only: not control_enabled
      },
      orchestrator: %{available: orchestrator_alive, paused: orchestrator_alive and Orchestrator.polling_paused?(orchestrator)}
    }
  end

  @spec issues_list_payload(GenServer.name(), timeout()) :: map()
  def issues_list_payload(orchestrator, snapshot_timeout_ms) do
    snapshot =
      case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
        %{} = s -> s
        _ -> %{running: [], retrying: []}
      end

    {tracker_issues, source_mode} =
      case Tracker.list_managed_issues() do
        {:ok, issues} -> {issues, "tracker"}
        {:error, _} -> {[], "snapshot"}
      end

    issues =
      tracker_issues
      |> Enum.map(&projection_from_tracker(&1, snapshot))
      |> Enum.reject(&is_nil/1)
      |> merge_running_only_issues(snapshot)

    %{
      generated_at: iso_now(),
      source: %{mode: source_mode, count: length(issues)},
      issues: issues
    }
  end

  @spec events_payload(map() | keyword()) :: map()
  def events_payload(filters) do
    events = EventStore.query(filters)

    %{
      generated_at: iso_now(),
      events: Enum.map(events, &Event.to_payload/1),
      count: length(events)
    }
  end

  @spec analytics_payload(GenServer.name(), timeout()) :: map()
  def analytics_payload(orchestrator, snapshot_timeout_ms) do
    snapshot =
      case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
        %{} = s -> s
        _ -> nil
      end

    events = EventStore.query(%{})
    Analytics.compute(events, snapshot)
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_for_issue_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_for_issue_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp recent_events_payload do
    EventStore.query(%{limit: 50})
    |> Enum.map(&Event.to_payload/1)
  rescue
    _ -> []
  end

  defp expanded_polling(snapshot) do
    polling = Map.get(snapshot, :polling) || %{}

    %{
      paused: Map.get(polling, :paused) == true,
      checking: Map.get(polling, :checking?) == true,
      next_poll_in_ms: Map.get(polling, :next_poll_in_ms),
      poll_interval_ms: Map.get(polling, :poll_interval_ms)
    }
  end

  defp expanded_capacity(snapshot) do
    max = Map.get(snapshot, :max_concurrent_agents) || 0
    running = length(Map.get(snapshot, :running, []))

    %{
      max: max,
      running: running,
      available: max(max - running, 0)
    }
  end

  defp orchestrator_status(%{paused: true}), do: "paused"
  defp orchestrator_status(_), do: "running"

  defp count_state(entries, state) when is_list(entries) and is_binary(state) do
    Enum.count(entries, &(Map.get(&1, :state) == state))
  end

  defp tokens_per_second_from_snapshot(snapshot) do
    totals = Map.get(snapshot, :codex_totals) || %{}
    seconds = Map.get(totals, :seconds_running) || 0
    total = Map.get(totals, :total_tokens) || 0
    if seconds > 0, do: Float.round(total / seconds, 2), else: 0
  end

  defp projection_from_tracker(%TrackerIssue{} = issue, snapshot) do
    running_entry =
      Enum.find(Map.get(snapshot, :running, []), fn %{issue_id: id} -> id == issue.id end)

    retry_entry =
      Enum.find(Map.get(snapshot, :retrying, []), fn %{issue_id: id} -> id == issue.id end)

    base = %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_number: parse_issue_number(issue.id),
      title: issue.title,
      state: issue.state,
      labels: Map.get(issue, :labels, []),
      assignee_id: issue.assignee_id,
      priority: issue.priority,
      branch: issue_branch_name(issue),
      pr_url: nil,
      created_at: iso8601(issue.created_at),
      updated_at: iso8601(issue.updated_at),
      agent_state: agent_state(running_entry, retry_entry, issue.state),
      worker_host: running_entry && Map.get(running_entry, :worker_host),
      workspace_path: running_entry && Map.get(running_entry, :workspace_path),
      runtime_seconds: running_entry && Map.get(running_entry, :runtime_seconds, 0),
      turn_count: running_entry && Map.get(running_entry, :turn_count, 0),
      tokens: running_entry_tokens(running_entry),
      last_event: running_entry && running_entry.last_codex_event,
      last_error: retry_entry && retry_entry.error
    }

    base
  end

  defp projection_from_tracker(_issue, _snapshot), do: nil

  defp running_entry_tokens(nil), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp running_entry_tokens(entry) do
    %{
      input_tokens: Map.get(entry, :codex_input_tokens, 0),
      output_tokens: Map.get(entry, :codex_output_tokens, 0),
      total_tokens: Map.get(entry, :codex_total_tokens, 0)
    }
  end

  defp agent_state(running, retry, fallback) do
    cond do
      running -> "running"
      retry -> "retrying"
      true -> fallback
    end
  end

  # Prefer the tracker-supplied `branch_name` (Linear populates this from
  # GraphQL; the GitHub `Issue.to_linear_issue/2` shim sets a synthesized
  # value when none is supplied). Only fall back to a numeric synthesis
  # when no `branch_name` exists and the id is a positive integer (i.e.
  # the GitHub case). UUID-like Linear ids must NOT be turned into a
  # bogus `symphony/issue-...` branch — that would mislead operators.
  defp issue_branch_name(%TrackerIssue{branch_name: branch})
       when is_binary(branch) and branch != "",
       do: branch

  defp issue_branch_name(%TrackerIssue{id: id}) when is_binary(id) do
    case parse_issue_number(id) do
      n when is_integer(n) -> "symphony/issue-#{n}"
      _ -> nil
    end
  end

  defp issue_branch_name(_), do: nil

  defp parse_issue_number(id) when is_binary(id) do
    # Require the parse to consume the entire string so UUID-like ids
    # ("1234abcd-...") and other non-numeric tracker ids don't get
    # turned into a misleading `symphony/issue-1234` branch name.
    case Integer.parse(id) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_issue_number(_), do: nil

  defp merge_running_only_issues(issues, snapshot) do
    # Build the known-id set from non-nil ids only. A nil id in the
    # tracker projection would otherwise let snapshot entries with a
    # nil `issue_id` masquerade as already-known and silently drop.
    known_ids =
      issues
      |> Enum.map(& &1.issue_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {extra_running, known_after_running} =
      collect_unknown_snapshot_entries(
        snapshot,
        :running,
        known_ids,
        &running_to_projection/1
      )

    {extra_retrying, _known_final} =
      collect_unknown_snapshot_entries(
        snapshot,
        :retrying,
        known_after_running,
        &retrying_to_projection/1
      )

    issues ++ extra_running ++ extra_retrying
  end

  defp collect_unknown_snapshot_entries(snapshot, key, known_ids, project_fun) do
    new_entries =
      snapshot
      |> Map.get(key, [])
      |> Enum.reject(fn entry ->
        is_nil(entry.issue_id) or MapSet.member?(known_ids, entry.issue_id)
      end)

    next_known =
      Enum.reduce(new_entries, known_ids, fn entry, acc ->
        MapSet.put(acc, entry.issue_id)
      end)

    {Enum.map(new_entries, project_fun), next_known}
  end

  defp running_to_projection(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_number: parse_issue_number(entry.issue_id),
      title: nil,
      state: entry.state,
      labels: [],
      assignee_id: nil,
      priority: nil,
      branch: nil,
      pr_url: nil,
      created_at: nil,
      updated_at: nil,
      agent_state: "running",
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      turn_count: Map.get(entry, :turn_count, 0),
      tokens: running_entry_tokens(entry),
      last_event: entry.last_codex_event,
      last_error: nil
    }
  end

  defp retrying_to_projection(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: Map.get(entry, :identifier),
      issue_number: parse_issue_number(entry.issue_id),
      title: nil,
      state: "retrying",
      labels: [],
      assignee_id: nil,
      priority: nil,
      branch: nil,
      pr_url: nil,
      created_at: nil,
      updated_at: nil,
      agent_state: "retrying",
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      runtime_seconds: 0,
      turn_count: 0,
      tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      last_event: nil,
      last_error: Map.get(entry, :error)
    }
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp iso_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
