defmodule SymphonyElixir.GitHub.Parser do
  @moduledoc """
  GitHub-issue body and label parsing helpers.

  Used by `SymphonyElixir.GitHub.Issue` and the eligibility logic in
  `SymphonyElixir.GitHub.Adapter`.
  """

  @priority_label_map %{
    "priority/urgent" => "urgent",
    "p0" => "urgent",
    "sev0" => "urgent",
    "priority/high" => "high",
    "p1" => "high",
    "sev1" => "high",
    "priority/medium" => "medium",
    "p2" => "medium",
    "sev2" => "medium",
    "priority/low" => "low",
    "p3" => "low",
    "sev3" => "low"
  }

  @doc """
  Map a list of label names to a priority string.

  Returns `nil` when no priority-flagged label is present. Earlier list
  entries win when multiple priority labels are set.
  """
  @spec priority_from_labels([String.t()]) :: String.t() | nil
  def priority_from_labels(labels) when is_list(labels) do
    Enum.find_value(labels, fn label ->
      Map.get(@priority_label_map, String.downcase(label))
    end)
  end

  def priority_from_labels(_), do: nil

  @doc """
  Extract issue numbers referenced from incomplete (unchecked) GitHub
  task-list items in `body`.

  Patterns recognized in unchecked tasks:

      - [ ] #123
      - [ ] owner/repo#123
      - [ ] https://github.com/owner/repo/issues/123

  Completed tasks (`- [x] ...`) and lines without an unchecked task marker
  are ignored. The returned list is unique and preserves first-seen order.
  """
  @spec blocked_by_from_body(String.t() | nil) :: [integer()]
  def blocked_by_from_body(nil), do: []
  def blocked_by_from_body(""), do: []

  def blocked_by_from_body(body) when is_binary(body) do
    body
    |> String.split(~r/\R/, trim: false)
    |> Enum.flat_map(&extract_blockers_from_line/1)
    |> Enum.uniq()
  end

  def blocked_by_from_body(_), do: []

  defp extract_blockers_from_line(line) do
    case Regex.run(~r/^\s*[-*+]\s*\[\s\]\s+(.+)$/, line, capture: :all_but_first) do
      [rest] ->
        extract_issue_numbers(rest)

      _ ->
        []
    end
  end

  defp extract_issue_numbers(text) do
    short = Regex.scan(~r/(?:^|[\s,;])#(\d+)\b/, text, capture: :all_but_first)
    cross = Regex.scan(~r/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+#(\d+)\b/, text, capture: :all_but_first)
    url = Regex.scan(~r/https?:\/\/github\.com\/[^\s\/]+\/[^\s\/]+\/issues\/(\d+)/, text, capture: :all_but_first)

    [short, cross, url]
    |> List.flatten()
    |> Enum.flat_map(fn raw ->
      case Integer.parse(raw) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
  end
end
