defmodule SymphonyElixir.GitHub.Issue do
  @moduledoc """
  Normalized GitHub issue used by the GitHub tracker adapter.

  This is the GitHub-shaped twin of `SymphonyElixir.Linear.Issue`. The
  orchestrator continues to expect a `SymphonyElixir.Linear.Issue` at the
  boundary, so this module also provides `to_linear_issue/1` for callers
  that need a struct compatible with the existing dashboard/orchestrator.
  """

  alias SymphonyElixir.Linear.Issue, as: LinearIssue

  defstruct [
    :id,
    :identifier,
    :number,
    :title,
    :description,
    :state,
    :url,
    :created_at,
    :updated_at,
    :branch_name,
    :priority,
    labels: [],
    assignees: [],
    blocked_by: []
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          number: integer() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          state: String.t() | nil,
          url: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          branch_name: String.t() | nil,
          priority: String.t() | nil,
          labels: [String.t()],
          assignees: [String.t()],
          blocked_by: [integer()]
        }

  @doc """
  Convert a `gh api`/`gh issue view --json` payload to an `Issue` struct.

  The function returns `nil` when the payload looks like a pull request
  (it carries a `pull_request` object) or when the required `number` field
  is missing. GitHub's REST issue endpoints can include PR-like rows; the
  caller is expected to drop nil entries.
  """
  @spec from_gh_payload(map()) :: t() | nil
  def from_gh_payload(%{"pull_request" => pr}) when is_map(pr), do: nil

  def from_gh_payload(payload) when is_map(payload) do
    case fetch_number(payload) do
      nil ->
        nil

      number ->
        body = string(payload["body"] || payload["description"] || "")
        labels = extract_labels(payload)
        assignees = extract_assignees(payload)

        %__MODULE__{
          id: string(payload["node_id"] || payload["id"]),
          identifier: "##{number}",
          number: number,
          title: string(payload["title"]),
          description: body,
          state: payload["state"] |> string() |> String.downcase(),
          url: string(payload["html_url"] || payload["url"]),
          created_at: parse_datetime(payload["createdAt"] || payload["created_at"]),
          updated_at: parse_datetime(payload["updatedAt"] || payload["updated_at"]),
          branch_name: "symphony/issue-#{number}",
          priority: SymphonyElixir.GitHub.Parser.priority_from_labels(labels),
          labels: labels,
          assignees: assignees,
          blocked_by: SymphonyElixir.GitHub.Parser.blocked_by_from_body(body)
        }
    end
  end

  def from_gh_payload(_), do: nil

  @doc """
  Convert an internal GitHub issue to a `SymphonyElixir.Linear.Issue` struct
  so existing orchestrator/dashboard code can keep using a single shape.

  Mappings:

  - `Linear.Issue.identifier` <- `"#<number>"`
  - `Linear.Issue.id` <- numeric `<number>` as string (used as the
    orchestrator's claim key; it must be deterministic and unique)
  - `Linear.Issue.priority` <- nil (Linear used integer priorities; GitHub
    uses label-derived strings; surfaced separately on the GitHub struct)
  - `Linear.Issue.state` <- the GitHub-derived label state
    (`"open"`, `"running"`, `"review"`, `"failed"`, `"blocked"`, `"closed"`)
    selected by the adapter at fetch time.
  """
  @spec to_linear_issue(t(), String.t()) :: LinearIssue.t()
  def to_linear_issue(%__MODULE__{} = issue, label_state) when is_binary(label_state) do
    %LinearIssue{
      id: Integer.to_string(issue.number),
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      priority: nil,
      state: label_state,
      branch_name: issue.branch_name,
      url: issue.url,
      assignee_id: List.first(issue.assignees),
      blocked_by:
        Enum.map(issue.blocked_by, fn n ->
          %{id: Integer.to_string(n), identifier: "##{n}", state: nil}
        end),
      labels: issue.labels,
      assigned_to_worker: true,
      created_at: issue.created_at,
      updated_at: issue.updated_at
    }
  end

  defp fetch_number(%{"number" => n}) when is_integer(n), do: n
  defp fetch_number(_), do: nil

  defp extract_labels(payload) do
    payload
    |> Map.get("labels", [])
    |> List.wrap()
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_assignees(payload) do
    payload
    |> Map.get("assignees", [])
    |> List.wrap()
    |> Enum.map(fn
      %{"login" => login} when is_binary(login) -> login
      login when is_binary(login) -> login
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: value
  defp string(value), do: to_string(value)
end
