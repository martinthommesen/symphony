defmodule SymphonyElixir.Redaction do
  @moduledoc """
  Centralized secret redaction for runner stdout/stderr, status output, and
  error logs.

  The redactor recognizes:

  - environment variables that hold tokens (`GH_TOKEN`, `GITHUB_TOKEN`,
    `COPILOT_GITHUB_TOKEN`, `SYMPHONY_CONTROL_TOKEN`,
    `SYMPHONY_SECRET_KEY_BASE`)
  - GitHub OAuth/PAT formats (`gho_`, `ghu_`, `ghs_`, `ghr_`, `ghp_`, plus
    fine-grained `github_pat_`)
  - `Authorization:` / `bearer` headers
  - URLs of the form `https://user:secret@host/...`
  - the literal value of the configured Symphony control token, when one
    is registered via `register_known_secret/1`

  Negative cases (ordinary text, plain English, non-token IDs) must not be
  redacted. The implementation prefers regex anchors that are unlikely to
  match documentation prose while still catching real tokens.
  """

  @placeholder "[REDACTED]"
  @persistent_term_key {__MODULE__, :known_secrets}

  @sensitive_env_vars ~w(GH_TOKEN GITHUB_TOKEN COPILOT_GITHUB_TOKEN SYMPHONY_CONTROL_TOKEN SYMPHONY_SECRET_KEY_BASE)

  # We deliberately drop word-boundary anchors. `\b` does not fire
  # between two word characters (so `prevtoken_gho_…` slipped past),
  # and a non-word lookbehind has the same gap. The pattern bodies
  # (`gh[oprsu]_` + 20+ alphanumerics; literal `bearer\s+`) are specific
  # enough to avoid false positives on prose, and over-redaction is the
  # right trade-off for a security control.
  @patterns [
    # Fine-grained GitHub PAT
    ~r/github_pat_[A-Za-z0-9_]{20,}/,
    # GitHub OAuth/installation/server/refresh/personal tokens.
    # `ghp_` and friends use a 36+ char body. We keep the lower bound at 20
    # to catch test fixtures while still rejecting "ghp_hello".
    ~r/gh[oprsu]_[A-Za-z0-9]{20,}/,
    # `Bearer <token>` anywhere (e.g. raw header without label).
    ~r/(?i)bearer\s+[A-Za-z0-9._\-+\/=]{16,}/,
    # URLs with embedded credentials: https://user:pw@host/...
    ~r/(https?:\/\/)([^\s:@\/]+):([^\s@\/]+)@/
  ]

  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  @spec sensitive_env_vars() :: [String.t()]
  def sensitive_env_vars, do: @sensitive_env_vars

  @doc """
  Register a literal value (e.g. the configured control token) for
  value-aware redaction.

  This catches the case where a token leaks without an `ENV_VAR=` prefix
  and without matching a recognized format — for example, an agent
  stdout line that simply prints the bearer value.

  Implementation note: `:persistent_term` is read-many/write-rarely.
  Updates trigger a global GC, but `register_known_secret/1` is called
  at most once per boot.
  """
  @spec register_known_secret(String.t()) :: :ok
  def register_known_secret(value) when is_binary(value) and byte_size(value) >= 16 do
    current = known_secrets()

    if MapSet.member?(current, value) do
      :ok
    else
      :persistent_term.put(@persistent_term_key, MapSet.put(current, value))
      :ok
    end
  end

  def register_known_secret(_), do: :ok

  @doc false
  @spec clear_known_secrets() :: :ok
  def clear_known_secrets do
    _ = :persistent_term.erase(@persistent_term_key)
    :ok
  end

  defp known_secrets do
    :persistent_term.get(@persistent_term_key, MapSet.new())
  end

  @doc """
  Redact tokens, bearer headers, and URL-embedded credentials in `value`.

  When `value` is not a binary, it is returned unchanged.
  """
  @spec redact(term()) :: term()
  def redact(value) when is_binary(value) do
    value
    |> redact_known_secret_values()
    |> redact_env_token_values()
    |> redact_authorization_headers()
    |> redact_with_patterns()
  end

  # Keep the `Authorization:` prefix and any `Bearer ` indicator so debug
  # logs retain context. Only the token body is replaced.
  defp redact_authorization_headers(value) do
    Regex.replace(
      ~r/(?i)(authorization\s*:\s*)(bearer\s+)?[A-Za-z0-9._\-+\/=]{8,}/,
      value,
      fn _full, prefix, scheme -> "#{prefix}#{scheme}#{@placeholder}" end
    )
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
      Regex.match?(~r/(?i)authorization\s*:\s*(bearer\s+)?[A-Za-z0-9._\-+\/=]{8,}/, value) or
      Enum.any?(@sensitive_env_vars, fn name ->
        Regex.match?(token_env_regex(name), value)
      end) or
      contains_known_secret?(value)
  end

  defp contains_known_secret?(value) do
    Enum.any?(known_secrets(), fn secret -> String.contains?(value, secret) end)
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

  defp redact_known_secret_values(value) do
    Enum.reduce(known_secrets(), value, fn secret, acc ->
      String.replace(acc, secret, @placeholder)
    end)
  end

  defp token_env_regex(name) do
    Regex.compile!(name <> "=([^\\s\"']+)")
  end
end
