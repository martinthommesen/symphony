defmodule SymphonyElixir.RepoId do
  @moduledoc """
  Validation helpers for `owner/repo` identifiers.

  Centralizes the regex used by every place that takes an `owner/repo` from
  config or user input. A repo identifier is allowed only if both segments
  match `[A-Za-z0-9._-]+` and are present. The slash is the only separator.
  """

  @repo_regex ~r/\A[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\z/

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: Regex.match?(@repo_regex, value)
  def valid?(_value), do: false

  @spec validate(term()) :: {:ok, String.t()} | {:error, :invalid_repo}
  def validate(value) do
    if valid?(value), do: {:ok, value}, else: {:error, :invalid_repo}
  end

  @spec split(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, :invalid_repo}
  def split(value) when is_binary(value) do
    if valid?(value) do
      [owner, name] = String.split(value, "/", parts: 2)
      {:ok, {owner, name}}
    else
      {:error, :invalid_repo}
    end
  end
end
