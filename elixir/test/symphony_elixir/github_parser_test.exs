defmodule SymphonyElixir.GitHub.ParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Parser

  describe "priority_from_labels/1" do
    test "maps known priority labels" do
      assert Parser.priority_from_labels(["priority/urgent"]) == "urgent"
      assert Parser.priority_from_labels(["P0"]) == "urgent"
      assert Parser.priority_from_labels(["sev0"]) == "urgent"
      assert Parser.priority_from_labels(["priority/high"]) == "high"
      assert Parser.priority_from_labels(["p1"]) == "high"
      assert Parser.priority_from_labels(["priority/medium"]) == "medium"
      assert Parser.priority_from_labels(["p2"]) == "medium"
      assert Parser.priority_from_labels(["priority/low"]) == "low"
      assert Parser.priority_from_labels(["p3"]) == "low"
    end

    test "case-insensitive" do
      assert Parser.priority_from_labels(["PRIORITY/URGENT"]) == "urgent"
      assert Parser.priority_from_labels(["P1"]) == "high"
    end

    test "returns nil for unknown labels" do
      assert Parser.priority_from_labels(["bug", "ui"]) == nil
      assert Parser.priority_from_labels([]) == nil
    end
  end

  describe "blocked_by_from_body/1" do
    test "extracts unchecked task references" do
      body = """
      ## blockers
      - [ ] #123
      - [x] #999
      - [ ] some/repo#42
      - [ ] https://github.com/owner/repo/issues/7
      not a task #555
      """

      assert Parser.blocked_by_from_body(body) == [123, 42, 7]
    end

    test "ignores completed tasks and prose" do
      body = """
      - [x] #5
      - [x] #6
      Some text mentioning #99 in passing.
      """

      assert Parser.blocked_by_from_body(body) == []
    end

    test "returns empty list for blank or nil bodies" do
      assert Parser.blocked_by_from_body("") == []
      assert Parser.blocked_by_from_body(nil) == []
    end

    test "deduplicates issue numbers" do
      body = """
      - [ ] #1
      - [ ] #1
      """

      assert Parser.blocked_by_from_body(body) == [1]
    end
  end
end
