defmodule SymphonyElixir.Observability.Event do
  @moduledoc """
  Neutral observability event used by the operations cockpit and event store.

  Events are redacted before storage, broadcast, and API delivery. Unknown
  event `:type` values are valid — clients must not crash on them.
  """

  alias SymphonyElixir.Redaction

  @enforce_keys [:id, :type, :severity, :timestamp]
  defstruct [
    :id,
    :type,
    :severity,
    :timestamp,
    :issue_id,
    :issue_identifier,
    :issue_number,
    :session_id,
    :worker_host,
    :workspace_path,
    :message,
    data: %{}
  ]

  @type severity :: :debug | :info | :warning | :error

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom() | String.t(),
          severity: severity(),
          timestamp: DateTime.t(),
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          issue_number: integer() | nil,
          session_id: String.t() | nil,
          worker_host: String.t() | nil,
          workspace_path: String.t() | nil,
          message: String.t() | nil,
          data: map()
        }

  @valid_severities [:debug, :info, :warning, :error]

  @doc """
  Build a new event from `attrs`. Stamps an ID and timestamp if absent and
  redacts every binary field plus all binary leaves of `data`.

  Unknown severities default to `:info`.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: attrs[:id] || generate_id(),
      type: normalize_type(attrs[:type]),
      severity: normalize_severity(attrs[:severity]),
      timestamp: normalize_timestamp(attrs[:timestamp]),
      issue_id: redact_binary(attrs[:issue_id]),
      issue_identifier: redact_binary(attrs[:issue_identifier]),
      issue_number: normalize_integer(attrs[:issue_number]),
      session_id: redact_binary(attrs[:session_id]),
      worker_host: redact_binary(attrs[:worker_host]),
      workspace_path: redact_binary(attrs[:workspace_path]),
      message: redact_binary(attrs[:message]),
      data: normalize_data(attrs[:data])
    }
  end

  @doc """
  Convert an event to a JSON-friendly map. ISO-8601 UTC timestamps and
  string-keyed values throughout.
  """
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = event) do
    %{
      id: event.id,
      type: type_to_string(event.type),
      severity: Atom.to_string(event.severity),
      timestamp: DateTime.to_iso8601(event.timestamp),
      issue_id: event.issue_id,
      issue_identifier: event.issue_identifier,
      issue_number: event.issue_number,
      session_id: event.session_id,
      worker_host: event.worker_host,
      workspace_path: event.workspace_path,
      message: event.message,
      data: event.data
    }
  end

  @doc """
  Severities considered valid — exposed for filters/tests.
  """
  @spec valid_severities() :: [severity()]
  def valid_severities, do: @valid_severities

  defp normalize_type(nil), do: :unknown
  defp normalize_type(value) when is_atom(value), do: value

  defp normalize_type(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: :unknown, else: trimmed
  end

  defp normalize_type(_), do: :unknown

  defp normalize_severity(value) when value in @valid_severities, do: value

  defp normalize_severity(value) when is_binary(value) do
    case String.downcase(value) do
      "debug" -> :debug
      "info" -> :info
      "warn" -> :warning
      "warning" -> :warning
      "error" -> :error
      _ -> :info
    end
  end

  defp normalize_severity(_), do: :info

  defp normalize_timestamp(%DateTime{} = ts), do: DateTime.shift_zone!(ts, "Etc/UTC") |> DateTime.truncate(:second)
  defp normalize_timestamp(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp redact_binary(nil), do: nil
  defp redact_binary(value) when is_binary(value), do: Redaction.redact(value)
  defp redact_binary(value) when is_atom(value), do: Atom.to_string(value)
  defp redact_binary(value), do: value

  defp normalize_data(nil), do: %{}
  defp normalize_data(value), do: redact_data(value)

  defp redact_data(nil), do: nil
  defp redact_data(value) when is_map(value), do: redact_map(value)
  defp redact_data(value) when is_list(value), do: redact_list(value)
  defp redact_data(value) when is_binary(value), do: Redaction.redact(value)
  defp redact_data(value), do: value

  defp redact_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      Map.put(acc, normalize_data_key(k), redact_data(v))
    end)
  end

  defp redact_list(list), do: Enum.map(list, &redact_data/1)

  defp normalize_data_key(key) when is_atom(key), do: key
  defp normalize_data_key(key) when is_binary(key), do: key
  defp normalize_data_key(key), do: to_string(key)

  defp type_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp type_to_string(value) when is_binary(value), do: value
  defp type_to_string(value), do: to_string(value)

  defp generate_id do
    "evt_" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
  end
end
