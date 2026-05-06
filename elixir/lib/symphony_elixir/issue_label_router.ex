defmodule SymphonyElixir.IssueLabelRouter do
  @moduledoc """
  Routes GitHub issue labels to configured agent IDs.
  """

  alias SymphonyElixir.Config

  @type issue :: map()
  @type routing_result ::
          {:ok, String.t(), [String.t()]}
          | {:error, :no_dispatch_label}
          | {:error, :blocked}
          | {:error, :running}
          | {:error, :review}
          | {:error, :failed}
          | {:error, {:ambiguous_agents, [String.t()]}}
          | {:error, {:multi_agent_policy_not_implemented, String.t(), [String.t()]}}
          | {:error, {:unsupported_agent, String.t()}}

  @doc """
  Resolve an issue's labels to a single agent ID.

  Returns:
  - `{:ok, agent_id, selected_labels}` - the agent to use
  - `{:error, reason}` - why routing failed
  """
  @spec resolve(issue()) :: routing_result()
  def resolve(%{labels: labels} = _issue) when is_list(labels) do
    settings = Config.settings!()
    routing = settings.agents.routing
    registry = settings.agents.registry

    label_strings = Enum.map(labels, &to_string/1)

    with :ok <- check_required_label(label_strings, routing.required_dispatch_label),
         :ok <- check_blocked_labels(label_strings, routing.blocked_labels || []),
         :ok <- check_running_label(label_strings, routing.running_label),
         :ok <- check_review_label(label_strings, routing.review_label),
         :ok <- check_failed_label(label_strings, routing.failed_label, routing.retry_failed) do
      resolve_agent(label_strings, routing, registry)
    end
  end

  def resolve(_issue) do
    {:error, :no_labels}
  end

  defp check_required_label(labels, required) when is_binary(required) and required != "" do
    if required in labels do
      :ok
    else
      {:error, :no_dispatch_label}
    end
  end

  defp check_required_label(_labels, _required), do: :ok

  defp check_blocked_labels(labels, blocked) when is_list(blocked) do
    blocked_set = MapSet.new(blocked)

    if Enum.any?(labels, &MapSet.member?(blocked_set, &1)) do
      {:error, :blocked}
    else
      :ok
    end
  end

  defp check_blocked_labels(_labels, _blocked), do: :ok

  defp check_running_label(labels, running) when is_binary(running) and running != "" do
    if running in labels do
      {:error, :running}
    else
      :ok
    end
  end

  defp check_running_label(_labels, _running), do: :ok

  defp check_review_label(labels, review) when is_binary(review) and review != "" do
    if review in labels do
      {:error, :review}
    else
      :ok
    end
  end

  defp check_review_label(_labels, _review), do: :ok

  defp check_failed_label(labels, failed, retry_failed)
       when is_binary(failed) and failed != "" do
    if failed in labels do
      if retry_failed do
        :ok
      else
        {:error, :failed}
      end
    else
      :ok
    end
  end

  defp check_failed_label(_labels, _failed, _retry_failed), do: :ok

  defp resolve_agent(labels, routing, registry) do
    prefix = routing.label_prefix || "symphony/agent/"
    default_agent = routing.default_agent
    multi_policy = routing.multi_agent_policy || "reject"
    aliases = routing.aliases || %{}

    agent_ids = extract_agent_ids(labels, prefix, aliases)

    resolve_agent_ids(agent_ids, labels, registry, default_agent, multi_policy)
  end

  defp extract_agent_ids(labels, prefix, aliases) do
    namespaced =
      labels
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.map(&String.replace_leading(&1, prefix, ""))

    bare =
      labels
      |> Enum.filter(fn label ->
        Map.has_key?(aliases, label) and label not in namespaced
      end)
      |> Enum.map(&Map.get(aliases, &1))

    if namespaced != [], do: namespaced, else: bare
  end

  defp resolve_agent_ids([], labels, registry, default_agent, _multi_policy) do
    if default_agent && Map.has_key?(registry, default_agent) do
      {:ok, default_agent, labels}
    else
      {:error, {:unsupported_agent, default_agent}}
    end
  end

  defp resolve_agent_ids([single], labels, registry, _default_agent, _multi_policy) do
    resolve_single_agent(single, labels, registry)
  end

  defp resolve_agent_ids(multiple, _labels, _registry, _default_agent, "reject") do
    {:error, {:ambiguous_agents, multiple}}
  end

  defp resolve_agent_ids(multiple, _labels, _registry, _default_agent, policy) do
    {:error, {:multi_agent_policy_not_implemented, policy, multiple}}
  end

  defp resolve_single_agent(single, labels, registry) do
    if Map.has_key?(registry, single) do
      agent_enabled?(Map.get(registry, single, %{}), single, labels)
    else
      {:error, {:unsupported_agent, single}}
    end
  end

  defp agent_enabled?(agent_config, single, labels) do
    if Map.get(agent_config, "enabled", true) do
      {:ok, single, labels}
    else
      {:error, {:unsupported_agent, single}}
    end
  end
end
