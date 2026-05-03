defmodule SymphonyElixir.Observability.EventTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Observability.Event

  describe "new/1" do
    test "stamps id, timestamp, and severity defaults" do
      event = Event.new(%{type: :poll_started})

      assert is_binary(event.id)
      assert event.severity == :info
      assert %DateTime{} = event.timestamp
      assert event.data == %{}
    end

    test "preserves caller-supplied id and timestamp" do
      ts = DateTime.from_naive!(~N[2026-01-01 00:00:00], "Etc/UTC")
      event = Event.new(%{id: "evt_test", type: :poll_started, timestamp: ts})

      assert event.id == "evt_test"
      assert event.timestamp == ts
    end

    test "rejects unknown severities and falls back to :info" do
      assert Event.new(%{type: :x, severity: :bogus}).severity == :info
      assert Event.new(%{type: :x, severity: "WARN"}).severity == :warning
      assert Event.new(%{type: :x, severity: "error"}).severity == :error
    end

    test "redacts secrets in the message and data fields" do
      ev =
        Event.new(%{
          type: :agent_stream_line,
          message: "exporting GH_TOKEN=ghp_abcdefghijklmnopqrstuv",
          data: %{
            "headers" => %{"Authorization" => "Bearer abcdefghijklmnopqrstuv1234"},
            "args" => ["--token", "github_pat_abcdefghijklmnopqrstuvwxyz"]
          }
        })

      refute String.contains?(ev.message, "ghp_abcdefghijklmnopqrstuv")
      assert String.contains?(ev.message, "[REDACTED]")
      refute Jason.encode!(ev.data) =~ "ghp_"
      refute Jason.encode!(ev.data) =~ "github_pat_"
    end

    test "tolerates nil and atom keys in data" do
      ev = Event.new(%{type: :agent_stream_line, data: %{:nested => %{"k" => nil}}})
      assert ev.data == %{nested: %{"k" => nil}}
    end
  end

  describe "to_payload/1" do
    test "returns ISO-8601 timestamps and string severity" do
      ts = DateTime.from_naive!(~N[2026-05-03 15:00:00], "Etc/UTC")
      payload = Event.to_payload(Event.new(%{type: :poll_completed, timestamp: ts, severity: :warning}))

      assert payload[:type] == "poll_completed"
      assert payload[:severity] == "warning"
      assert payload[:timestamp] == DateTime.to_iso8601(ts)
    end

    test "round-trips through JSON without losing keys" do
      ev =
        Event.new(%{
          type: "agent_stream_line",
          severity: :info,
          issue_identifier: "GH-1",
          message: "hello",
          data: %{"k" => 1}
        })

      assert {:ok, json} = Jason.encode(Event.to_payload(ev))
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["issue_identifier"] == "GH-1"
      assert decoded["message"] == "hello"
      assert decoded["data"] == %{"k" => 1}
    end
  end
end
