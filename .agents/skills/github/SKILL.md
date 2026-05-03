---
name: github
description: |
  Use `gh api` for raw GitHub REST and GraphQL operations such as querying
  issues and PRs, posting comments, managing labels, and reading review state.
---

# GitHub API

Use this skill for raw GitHub API work during sessions. Prefer `gh api` over
direct `curl` calls — it handles authentication automatically.

## Primary tool

```sh
gh api <endpoint> [flags]
```

Key flags:

| Flag | Purpose |
| --- | --- |
| `-X POST` | Change HTTP method |
| `-f key=value` | String field in request body |
| `-F key=value` | Auto-typed field (numbers, booleans, files) |
| `--jq '<expr>'` | Filter response with jq |
| `--paginate` | Fetch all pages |
| `-H 'Accept: ...'` | Override Accept header |

For GraphQL:

```sh
gh api graphql -f query='<document>' -f variables='<json>'
```

## Resolving `{owner}` and `{repo}`

`gh api` expands `{owner}` and `{repo}` from the current repo automatically.
You can also use the `:owner/:repo` shorthand in REST paths, or pass
`-F owner=... -F repo=...` for GraphQL variables.

## Common REST workflows

### Get a pull request

```sh
gh api repos/{owner}/{repo}/pulls/<pr_number>
```

### List open pull requests

```sh
gh api repos/{owner}/{repo}/pulls --jq '.[].number'
```

### Get an issue

```sh
gh api repos/{owner}/{repo}/issues/<number>
```

### List issue comments

```sh
gh api repos/{owner}/{repo}/issues/<number>/comments
```

### Post an issue comment

```sh
gh api -X POST repos/{owner}/{repo}/issues/<number>/comments \
  -f body='<text>'
```

### List PR review comments (inline)

```sh
gh api repos/{owner}/{repo}/pulls/<pr_number>/comments
```

### Reply to a PR review comment

```sh
gh api -X POST repos/{owner}/{repo}/pulls/<pr_number>/comments \
  -f body='<text>' \
  -F in_reply_to=<comment_id>
```

`in_reply_to` must be the **numeric** comment id, not the GraphQL node id
(`PRRC_...`). Get it from `.id` in the list response.

### List PR reviews

```sh
gh api repos/{owner}/{repo}/pulls/<pr_number>/reviews
```

### Request reviewers

```sh
gh api -X POST repos/{owner}/{repo}/pulls/<pr_number>/requested_reviewers \
  -f 'reviewers[]=<username>'
```

### Add a label to an issue or PR

```sh
gh api -X POST repos/{owner}/{repo}/issues/<number>/labels \
  -f 'labels[]=<label>'
```

### List labels on a repo

```sh
gh api repos/{owner}/{repo}/labels --jq '.[].name'
```

### Get workflow runs for a PR (by head SHA)

```sh
sha=$(gh api repos/{owner}/{repo}/pulls/<pr_number> --jq '.head.sha')
gh api "repos/{owner}/{repo}/actions/runs?head_sha=$sha" \
  --jq '.workflow_runs[] | {id, name, status, conclusion}'
```

### Re-run a workflow

```sh
gh api -X POST repos/{owner}/{repo}/actions/runs/<run_id>/rerun
```

## Common GraphQL workflows

Use GraphQL when you need nested data or fields not available in REST.

### Get PR with review state and files changed

```graphql
query PRDetails($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      number
      title
      state
      mergeable
      headRefName
      headRefOid
      baseRefName
      reviews(last: 10) {
        nodes {
          id
          author { login }
          state
          submittedAt
        }
      }
      reviewRequests(last: 10) {
        nodes {
          requestedReviewer {
            ... on User { login }
          }
        }
      }
      files(first: 50) {
        nodes {
          path
          additions
          deletions
        }
      }
    }
  }
}
```

```sh
gh api graphql \
  -f query='<document>' \
  -f owner='{owner}' \
  -f repo='{repo}' \
  -F number=<pr_number>
```

### List a user's open PRs in the repo

```graphql
query OpenPRs($owner: String!, $repo: String!, $author: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequests(
      states: [OPEN]
      first: 20
      orderBy: { field: UPDATED_AT, direction: DESC }
    ) {
      nodes {
        number
        title
        author { login }
        createdAt
        updatedAt
      }
    }
  }
}
```

### Get PR check/status summary

```graphql
query PRChecks($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              state
              contexts(first: 20) {
                nodes {
                  ... on CheckRun {
                    name
                    status
                    conclusion
                    detailsUrl
                  }
                  ... on StatusContext {
                    context
                    state
                    targetUrl
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
```

### Get issue with labels, assignees, and project state

```graphql
query IssueDetails($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      id
      number
      title
      state
      body
      labels(first: 10) {
        nodes { name color }
      }
      assignees(first: 5) {
        nodes { login }
      }
      comments(last: 5) {
        nodes {
          id
          author { login }
          body
          createdAt
        }
      }
    }
  }
}
```

## Discovering unfamiliar fields

Introspect a type:

```sh
gh api graphql -f query='
  query {
    __type(name: "PullRequest") {
      fields {
        name
        type { kind name ofType { kind name } }
      }
    }
  }
'
```

List top-level query fields:

```sh
gh api graphql -f query='
  query { __type(name: "Query") { fields { name } } }
'
```

## Usage rules

- Prefer REST for simple single-resource reads and writes; use GraphQL for
  nested or multi-resource queries that would require multiple REST calls.
- Always use the numeric comment id (`.id`) not the node id for
  `in_reply_to` on review comment replies.
- When paginating, add `--paginate` rather than manually incrementing pages.
- Do not hardcode tokens; rely on `gh auth` and `GH_TOKEN` already present in
  the session.
- A 404 on a review comment reply usually means the endpoint is missing the PR
  number — double-check the path includes `/pulls/<pr_number>/comments`.
