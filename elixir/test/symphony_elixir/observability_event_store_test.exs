defmodule SymphonyElixir.Observability.EventStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Observability.{Event, EventStore}

  setup do
    case Process.whereis(SymphonyElixir.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: SymphonyElixir.PubSub})
      _ -> :ok
    end

    # Use a dedicated subdirectory so `on_exit` can `rm_rf` the test's
    # own temp tree without touching unrelated files in `System.tmp_dir!()`.
    test_dir = Path.join(System.tmp_dir!(), "symphony-events-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    tmp = Path.join(test_dir, "events.jsonl")
    on_exit(fn -> File.rm_rf(test_dir) end)

    name = String.to_atom("event_store_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      EventStore.start_link(
        name: name,
        buffer_size: 5,
        jsonl_enabled: true,
        jsonl_path: tmp
      )

    %{pid: pid, name: name, jsonl: tmp}
  end

  test "appends and queries events", %{name: name} do
    EventStore.emit(%{type: :poll_started}, name)
    EventStore.emit(%{type: :poll_completed, issue_identifier: "GH-1"}, name)

    assert events = EventStore.query(%{}, name)
    assert length(events) == 2

    [filtered] = EventStore.query(%{issue_identifier: "GH-1"}, name)
    assert filtered.issue_identifier == "GH-1"
  end

  test "ring buffer evicts oldest events", %{name: name} do
    Enum.each(1..10, fn n -> EventStore.emit(%{type: :tick, message: "#{n}"}, name) end)
    events = EventStore.query(%{}, name)
    assert length(events) == 5
    messages = Enum.map(events, & &1.message)
    assert messages == ["6", "7", "8", "9", "10"]
  end

  test "broadcasts events to subscribers", %{name: name} do
    :ok = EventStore.subscribe()
    EventStore.emit(%{type: :agent_started, issue_identifier: "GH-7"}, name)

    assert_receive {:observability_event, %Event{type: :agent_started, issue_identifier: "GH-7"}}, 200
  end

  test "redacts secrets before persistence and broadcast", %{name: name, jsonl: jsonl} do
    :ok = EventStore.subscribe()

    EventStore.emit(
      %{
        type: :agent_stream_line,
        message: "GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz body"
      },
      name
    )

    assert_receive {:observability_event, %Event{message: msg}}, 200
    refute msg =~ "ghp_abcdefghijklmnopqrstuv"
    assert msg =~ "[REDACTED]"

    # JSONL line should also be redacted.
    Process.sleep(50)
    contents = File.read!(jsonl)
    refute contents =~ "ghp_abcdefghijklmnopqrstuv"
    assert contents =~ "[REDACTED]"
  end

  test "persists events as one JSON object per line", %{name: name, jsonl: jsonl} do
    EventStore.emit(%{type: :poll_started}, name)
    EventStore.emit(%{type: :poll_completed}, name)
    Process.sleep(50)

    contents = File.read!(jsonl)
    [line1, line2] = String.split(String.trim(contents), "\n")
    assert {:ok, %{"type" => "poll_started"}} = Jason.decode(line1)
    assert {:ok, %{"type" => "poll_completed"}} = Jason.decode(line2)
  end

  test "JSONL persistence failure does not crash store", %{name: name} do
    bad_path = "/nonexistent/dir-#{System.unique_integer([:positive])}/events.jsonl"

    name = String.to_atom("#{name}_bad")

    {:ok, _pid} =
      EventStore.start_link(name: name, buffer_size: 4, jsonl_enabled: true, jsonl_path: bad_path)

    EventStore.emit(%{type: :tick}, name)
    EventStore.emit(%{type: :tick}, name)

    stats = EventStore.stats(name)
    assert stats.length == 2
    # We can't predict mkdir success in every environment, but the store
    # is still alive and serving queries.
    assert is_integer(stats.jsonl_failures)
  end

  test "loads recent history from JSONL on startup, skipping malformed lines", %{jsonl: jsonl} do
    # Pre-populate the JSONL file with a malformed line and a valid one.
    File.mkdir_p!(Path.dirname(jsonl))
    valid = Jason.encode!(%{id: "evt_1", type: "poll_started", severity: "info", timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})

    File.write!(jsonl, "this is not json\n" <> valid <> "\n")

    name = String.to_atom("event_store_load_#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      EventStore.start_link(name: name, buffer_size: 5, jsonl_enabled: true, jsonl_path: jsonl)

    events = EventStore.query(%{}, name)
    assert [%Event{id: "evt_1"}] = events
  end

  test "applies since filter as ISO timestamp", %{name: name} do
    t1 = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    t2 = DateTime.utc_now() |> DateTime.truncate(:second)

    EventStore.emit(%{type: :a, timestamp: t1}, name)
    EventStore.emit(%{type: :b, timestamp: t2}, name)

    [event] = EventStore.query(%{since: DateTime.to_iso8601(t2)}, name)
    assert event.type in [:b, "b"]
  end

  test "limit returns most recent N events", %{name: name} do
    Enum.each(1..5, fn n -> EventStore.emit(%{type: :tick, message: "#{n}"}, name) end)
    events = EventStore.query(%{limit: 2}, name)
    assert Enum.map(events, & &1.message) == ["4", "5"]
  end
end
