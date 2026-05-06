defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.{LogFile, Redaction}
  alias SymphonyElixir.Observability.Control

  @impl true
  def start(_type, _args) do
    :ok = LogFile.configure()

    # Register the configured control token (if any) for value-aware
    # redaction. Catches cases where the literal token leaks via agent
    # stdout without an `ENV_VAR=` or `Bearer` prefix.
    case Control.configured_token() do
      token when is_binary(token) -> Redaction.register_known_secret(token)
      _ -> :ok
    end

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.StructuredLogger,
      SymphonyElixir.Observability.EventStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
