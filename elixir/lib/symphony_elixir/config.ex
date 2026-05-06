defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec agent_config(String.t()) :: map() | nil
  def agent_config(agent_id) when is_binary(agent_id) do
    settings = settings!()
    Map.get(settings.agents.registry, agent_id)
  end

  @spec default_agent() :: String.t()
  def default_agent do
    settings!().agents.routing.default_agent
  end

  @spec acpx_executable() :: String.t()
  def acpx_executable do
    settings!().acpx.executable
  end

  @spec agent_timeout_ms(String.t()) :: non_neg_integer()
  def agent_timeout_ms(agent_id) when is_binary(agent_id) do
    case agent_config(agent_id) do
      nil ->
        3_600_000

      config ->
        runtime = Map.get(config, "runtime", %{})
        (Map.get(config, "timeout_seconds") || Map.get(runtime, "timeout_seconds", 3600)) * 1_000
    end
  end

  @spec agent_read_timeout_ms() :: non_neg_integer()
  def agent_read_timeout_ms do
    5_000
  end

  @spec agent_stall_timeout_ms() :: non_neg_integer()
  def agent_stall_timeout_ms do
    settings!().agent.stall_timeout_ms
  end

  defp validate_semantics(settings) do
    with :ok <- validate_tracker_kind(settings.tracker),
         :ok <- validate_linear_settings(settings.tracker) do
      validate_github_settings(settings.tracker)
    end
  end

  defp validate_tracker_kind(%{kind: nil}), do: {:error, :missing_tracker_kind}

  defp validate_tracker_kind(%{kind: kind}) when kind in ["linear", "memory", "github"], do: :ok
  defp validate_tracker_kind(%{kind: kind}), do: {:error, {:unsupported_tracker_kind, kind}}

  defp validate_linear_settings(%{kind: "linear", api_key: key}) when not is_binary(key),
    do: {:error, :missing_linear_api_token}

  defp validate_linear_settings(%{kind: "linear", project_slug: slug}) when not is_binary(slug),
    do: {:error, :missing_linear_project_slug}

  defp validate_linear_settings(_), do: :ok

  defp validate_github_settings(%{kind: "github", repo: repo}) do
    if SymphonyElixir.RepoId.valid?(repo), do: :ok, else: {:error, :missing_or_invalid_github_repo}
  end

  defp validate_github_settings(_), do: :ok

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
