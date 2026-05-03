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

    # Run anonymously (`name: false`) so we don't have to mint a fresh
    # atom per test. Atoms aren't garbage-collected, so dynamic
    # `String.to_atom/1` would also trip Credo's UnsafeToAtom check.
    {:ok, pid} =
      EventStore.start_link(
        name: false,
        buffer_size: 5,
        jsonl_enabled: true,
        jsonl_path: tmp
      )

    %{pid: pid, jsonl: tmp}
  end

  test "appends and queries events", %{pid: pid} do
    EventStore.emit(%{type: :poll_started}, pid)
    EventStore.emit(%{type: :poll_completed, issue_identifier: "GH-1"}, pid)

    assert events = EventStore.query(%{}, pid)
    assert length(events) == 2

    [filtered] = EventStore.query(%{issue_identifier: "GH-1"}, pid)
    assert filtered.issue_identifier == "GH-1"
  end

  test "ring buffer evicts oldest events", %{pid: pid} do
    Enum.each(1..10, fn n -> EventStore.emit(%{type: :tick, message: "#{n}"}, pid) end)
    events = EventStore.query(%{}, pid)
    assert length(events) == 5
    messages = Enum.map(events, & &1.message)
    assert messages == ["6", "7", "8", "9", "10"]
  end

  test "broadcasts events to subscribers", %{pid: pid} do
    :ok = EventStore.subscribe()
    # Use a unique issue_identifier so this test can't pick up an
    # ambient event from the application's global EventStore that
    # publishes on the same PubSub topic.
    marker = "GH-bcast-#{System.unique_integer([:positive])}"
    EventStore.emit(%{type: :agent_started, issue_identifier: marker}, pid)

    assert_receive {:observability_event, %Event{type: :agent_started, issue_identifier: ^marker}}, 200
  end

  test "redacts secrets before persistence and broadcast", %{pid: pid, jsonl: jsonl} do
    :ok = EventStore.subscribe()

    marker = "GH-redact-#{System.unique_integer([:positive])}"

    EventStore.emit(
      %{
        type: :agent_stream_line,
        issue_identifier: marker,
        message: "GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz body"
      },
      pid
    )

    assert_receive {:observability_event, %Event{message: msg, issue_identifier: ^marker}}, 200
    refute msg =~ "ghp_abcdefghijklmnopqrstuv"
    assert msg =~ "[REDACTED]"

    # JSONL line should also be redacted.
    Process.sleep(50)
    contents = File.read!(jsonl)
    refute contents =~ "ghp_abcdefghijklmnopqrstuv"
    assert contents =~ "[REDACTED]"
  end

  test "persists events as one JSON object per line", %{pid: pid, jsonl: jsonl} do
    EventStore.emit(%{type: :poll_started}, pid)
    EventStore.emit(%{type: :poll_completed}, pid)
    Process.sleep(50)

    contents = File.read!(jsonl)
    [line1, line2] = String.split(String.trim(contents), "\n")
    assert {:ok, %{"type" => "poll_started"}} = Jason.decode(line1)
    assert {:ok, %{"type" => "poll_completed"}} = Jason.decode(line2)
  end

  test "JSONL persistence failure increments jsonl_failures and does not crash store" do
    # Force a deterministic mkdir-then-write failure: write to the
    # filesystem root which is not writable by the test process. On
    # macOS+Linux the test runner is non-root, so `/nonexistent/...`
    # `mkdir_p` succeeds in a parent we can't reach (returns :eacces
    # via {:error, :enoent} when the leading mount is read-only) — to
    # remove the platform variance, point at `/dev/null/.../events.jsonl`
    # which can never be created (mkdir_p on a sub-path of a regular
    # file returns ENOTDIR on every Unix).
    bad_path = "/dev/null/symphony-events-#{System.unique_integer([:positive])}/events.jsonl"

    {:ok, pid} =
      EventStore.start_link(
        name: false,
        buffer_size: 4,
        jsonl_enabled: true,
        jsonl_path: bad_path
      )

    EventStore.emit(%{type: :tick}, pid)
    EventStore.emit(%{type: :tick}, pid)

    # Casts are async; give the store a tick to drain.
    Process.sleep(50)
    stats = EventStore.stats(pid)

    assert stats.length == 2,
           "store should still serve queries even when persistence fails"

    assert stats.jsonl_failures >= 2,
           "expected jsonl_failures >= 2 (one per emit); got #{stats.jsonl_failures}"
  end

  test "apply_since with an evicted event id returns [] instead of replaying everything", %{pid: pid} do
    Enum.each(1..10, fn n -> EventStore.emit(%{type: :tick, message: "#{n}"}, pid) end)

    # The ring is sized at 5 in setup; ids from the first five emits are
    # gone. Asking for events `since=evt_does_not_exist` must not flood
    # the caller with the entire current ring (which would re-deliver
    # already-seen events on SSE reconnect).
    assert EventStore.query(%{since: "evt_does_not_exist"}, pid) == []

    # A since= that matches an id still in the ring keeps replaying
    # only what came after it.
    [first | _] = EventStore.query(%{}, pid)
    after_first = EventStore.query(%{since: first.id}, pid)
    refute Enum.any?(after_first, fn ev -> ev.id == first.id end)
  end

  test "EventStore.query honours an explicit timeout when the GenServer is busy" do
    # Spawn a frozen process that *looks* like a GenServer to the
    # caller but never replies. We pass the pid directly to avoid
    # minting a runtime atom — `String.to_atom/1` on a unique value
    # would leak atoms (BEAM doesn't GC them) and trips Credo's
    # UnsafeToAtom check.
    pid =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    assert EventStore.query(%{}, pid, 25) == []

    Process.exit(pid, :kill)
  end

  test "loads recent history from JSONL on startup, skipping malformed lines", %{jsonl: jsonl} do
    # Pre-populate the JSONL file with a malformed line and a valid one.
    File.mkdir_p!(Path.dirname(jsonl))

    valid =
      Jason.encode!(%{
        id: "evt_1",
        type: "poll_started",
        severity: "info",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.write!(jsonl, "this is not json\n" <> valid <> "\n")

    {:ok, pid} =
      EventStore.start_link(
        name: false,
        buffer_size: 5,
        jsonl_enabled: true,
        jsonl_path: jsonl
      )

    events = EventStore.query(%{}, pid)
    assert [%Event{id: "evt_1"}] = events
  end

  test "applies since filter as ISO timestamp", %{pid: pid} do
    t1 = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    t2 = DateTime.utc_now() |> DateTime.truncate(:second)

    EventStore.emit(%{type: :a, timestamp: t1}, pid)
    EventStore.emit(%{type: :b, timestamp: t2}, pid)

    [event] = EventStore.query(%{since: DateTime.to_iso8601(t2)}, pid)
    assert event.type in [:b, "b"]
  end

  test "limit returns most recent N events", %{pid: pid} do
    Enum.each(1..5, fn n -> EventStore.emit(%{type: :tick, message: "#{n}"}, pid) end)
    events = EventStore.query(%{limit: 2}, pid)
    assert Enum.map(events, & &1.message) == ["4", "5"]
  end
end
