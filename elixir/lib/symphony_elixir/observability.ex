defmodule SymphonyElixir.Observability do
  @moduledoc """
  Convenience facade for observability event emission. The orchestrator,
  agent runner, finalizer, and control endpoints emit events via this module
  rather than calling `EventStore` directly so we can change the back end
  later without touching call sites.

  Emitting an event is a `cast` (fire-and-forget). It is safe to call from
  any process and will not block on disk I/O even when JSONL persistence is
  enabled.
  """

  alias SymphonyElixir.Observability.{Event, EventStore}

  @spec emit(atom() | String.t(), map() | keyword()) :: Event.t()
  def emit(type, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:type, type)
      |> Map.put_new(:severity, :info)

    EventStore.emit(attrs)
  end

  @spec emit_warning(atom() | String.t(), map() | keyword()) :: Event.t()
  def emit_warning(type, attrs \\ %{}), do: emit_with(type, attrs, :warning)

  @spec emit_error(atom() | String.t(), map() | keyword()) :: Event.t()
  def emit_error(type, attrs \\ %{}), do: emit_with(type, attrs, :error)

  @spec emit_debug(atom() | String.t(), map() | keyword()) :: Event.t()
  def emit_debug(type, attrs \\ %{}), do: emit_with(type, attrs, :debug)

  defp emit_with(type, attrs, severity) do
    attrs
    |> Map.new()
    |> Map.put(:severity, severity)
    |> Map.put_new(:type, type)
    |> EventStore.emit()
  end
end
