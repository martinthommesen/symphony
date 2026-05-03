defmodule SymphonyElixir.Redaction do
  @moduledoc """
  Centralized secret redaction for runner stdout/stderr, status output, and
  error logs.

  The redactor recognizes:

  - environment variables that hold tokens (`GH_TOKEN`, `GITHUB_TOKEN`,
    `COPILOT_GITHUB_TOKEN`)
  - GitHub OAuth/PAT formats (`gho_`, `ghu_`, `ghs_`, `ghr_`, `ghp_`, plus
    fine-grained `github_pat_`)
  - `Authorization:` / `bearer` headers
  - URLs of the form `https://user:secret@host/...`

  Negative cases (ordinary text, plain English, non-token IDs) must not be
  redacted. The implementation prefers regex anchors that are unlikely to
  match documentation prose while still catching real tokens.
  """

  @placeholder "[REDACTED]"

  @sensitive_env_vars ~w(GH_TOKEN GITHUB_TOKEN COPILOT_GITHUB_TOKEN)

  @patterns [
    # Fine-grained GitHub PAT
    ~r/github_pat_[A-Za-z0-9_]{20,}/,
    # GitHub OAuth/installation/server/refresh/personal tokens.
    # `ghp_` and friends use a 36+ char body. We keep the lower bound at 20
    # to catch test fixtures while still rejecting "ghp_hello".
    ~r/\bgh[oprsu]_[A-Za-z0-9]{20,}/,
    # Authorization headers: `Authorization: Bearer <token>` or `Bearer <token>`.
    ~r/(?i)(authorization\s*:\s*)(bearer\s+)?[A-Za-z0-9._\-+\/=]{8,}/,
    ~r/(?i)\bbearer\s+[A-Za-z0-9._\-+\/=]{16,}/,
    # URLs with embedded credentials: https://user:pw@host/...
    ~r/(https?:\/\/)([^\s:@\/]+):([^\s@\/]+)@/
  ]

  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  @spec sensitive_env_vars() :: [String.t()]
  def sensitive_env_vars, do: @sensitive_env_vars

  @doc """
  Redact tokens, bearer headers, and URL-embedded credentials in `value`.

  When `value` is not a binary, it is returned unchanged.
  """
  @spec redact(term()) :: term()
  def redact(value) when is_binary(value) do
    value
    |> redact_env_token_values()
    |> redact_with_patterns()
  end

  def redact(value), do: value

  @doc """
  Iolist-friendly redaction for callers that may pass IO data.
  """
  @spec redact_io(iodata()) :: iodata()
  def redact_io(value) when is_binary(value), do: redact(value)
  def redact_io(value) when is_list(value), do: value |> IO.iodata_to_binary() |> redact()
  def redact_io(value), do: value

  @doc """
  Returns `true` when the binary contains a recognized token form.

  Helpful for tests that want to assert "this should be redacted".
  """
  @spec contains_secret?(String.t()) :: boolean()
  def contains_secret?(value) when is_binary(value) do
    Enum.any?(@patterns, &Regex.match?(&1, value)) or
      Enum.any?(@sensitive_env_vars, fn name ->
        Regex.match?(token_env_regex(name), value)
      end)
  end

  defp redact_with_patterns(value) do
    Enum.reduce(@patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, @placeholder)
    end)
  end

  defp redact_env_token_values(value) do
    Enum.reduce(@sensitive_env_vars, value, fn name, acc ->
      regex = token_env_regex(name)
      Regex.replace(regex, acc, "#{name}=#{@placeholder}")
    end)
  end

  defp token_env_regex(name) do
    Regex.compile!(name <> "=([^\\s\"']+)")
  end
end
