defmodule SymphonyElixir.GitHub.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Issue

  describe "from_gh_payload/1" do
    test "normalizes a typical gh api issue payload" do
      payload = %{
        "id" => 1,
        "node_id" => "I_kwDOABCDEF",
        "number" => 42,
        "title" => "Add caching",
        "body" => "Please add caching.",
        "state" => "open",
        "html_url" => "https://github.com/owner/repo/issues/42",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-02-01T00:00:00Z",
        "labels" => [%{"name" => "Symphony"}, %{"name" => "p1"}],
        "assignees" => [%{"login" => "alice"}, %{"login" => "bob"}]
      }

      assert %Issue{} = issue = Issue.from_gh_payload(payload)
      assert issue.number == 42
      assert issue.identifier == "#42"
      assert issue.title == "Add caching"
      assert issue.description == "Please add caching."
      assert issue.state == "open"
      assert issue.url == "https://github.com/owner/repo/issues/42"
      assert issue.branch_name == "symphony/issue-42"
      assert issue.priority == "high"
      assert issue.labels == ["symphony", "p1"]
      assert issue.assignees == ["alice", "bob"]
      assert issue.id == "I_kwDOABCDEF"
    end

    test "drops payloads that look like pull requests" do
      payload = %{
        "number" => 17,
        "title" => "PR",
        "pull_request" => %{"url" => "..."}
      }

      assert Issue.from_gh_payload(payload) == nil
    end

    test "returns nil when number is missing" do
      assert Issue.from_gh_payload(%{"title" => "x"}) == nil
    end

    test "extracts blocked-by from body task list" do
      payload = %{
        "number" => 9,
        "title" => "epic",
        "body" => "tasks:\n- [ ] #1\n- [ ] #2\n- [x] #3",
        "state" => "open"
      }

      assert %Issue{blocked_by: [1, 2]} = Issue.from_gh_payload(payload)
    end

    test "to_linear_issue/2 produces a Linear-compatible struct" do
      payload = %{"number" => 5, "title" => "t", "body" => "", "state" => "open", "labels" => []}
      issue = Issue.from_gh_payload(payload)
      linear = Issue.to_linear_issue(issue, "running")

      assert linear.id == "5"
      assert linear.identifier == "#5"
      assert linear.state == "running"
      assert linear.branch_name == "symphony/issue-5"
    end
  end
end
