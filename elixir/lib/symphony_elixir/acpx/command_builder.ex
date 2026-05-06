defmodule SymphonyElixir.Acpx.CommandBuilder do
  @moduledoc """
  Builds acpx argv lists with no shell interpolation.
  """

  alias SymphonyElixir.Config

  @type agent_id :: String.t()
  @type workspace :: String.t()
  @type session_name :: String.t()
  @type prompt_path :: String.t()

  @doc """
  Build argv for `acpx sessions ensure`.
  """
  @spec ensure_session(agent_id(), workspace(), session_name()) :: [String.t()]
  def ensure_session(agent_id, workspace, session_name) do
    base = base_argv(agent_id, workspace)
    base ++ ["sessions", "ensure", "--name", session_name]
  end

  @doc """
  Build argv for `acpx prompt` via session.
  """
  @spec prompt(agent_id(), workspace(), session_name(), prompt_path()) :: [String.t()]
  def prompt(agent_id, workspace, session_name, prompt_path) do
    base = base_argv(agent_id, workspace)
    base ++ ["-s", session_name, "--file", prompt_path]
  end

  @doc """
  Build argv for `acpx cancel`.
  """
  @spec cancel(agent_id(), workspace(), session_name()) :: [String.t()]
  def cancel(agent_id, workspace, session_name) do
    [
      "--cwd",
      workspace
    ] ++
      agent_argv(agent_id) ++
      [
        "-s",
        session_name,
        "cancel"
      ]
  end

  @doc """
  Build argv for `acpx status`.
  """
  @spec status(agent_id(), workspace(), session_name()) :: [String.t()]
  def status(agent_id, workspace, session_name) do
    [
      "--cwd",
      workspace,
      "--format",
      "json"
    ] ++
      agent_argv(agent_id) ++
      [
        "-s",
        session_name,
        "status"
      ]
  end

  @doc """
  Return the configured acpx executable path.
  """
  @spec executable() :: String.t()
  def executable do
    Config.acpx_executable()
  end

  defp base_argv(agent_id, workspace) do
    acpx = Config.settings!().acpx
    agent_config = Config.agent_config(agent_id) || %{}

    runtime = Map.get(agent_config, "runtime", %{})
    model = Map.get(agent_config, "model", %{})

    timeout = Map.get(agent_config, "timeout_seconds") || Map.get(runtime, "timeout_seconds", 3600)
    ttl = Map.get(agent_config, "ttl_seconds") || Map.get(runtime, "ttl_seconds", 300)

    argv = [
      "--cwd",
      workspace,
      "--format",
      acpx.default_output_format,
      permission_flag(agent_config, acpx)
    ]

    argv = if acpx.json_strict, do: argv ++ ["--json-strict"], else: argv
    argv = if acpx.suppress_reads, do: argv ++ ["--suppress-reads"], else: argv

    argv = argv ++ ["--timeout", to_string(timeout), "--ttl", to_string(ttl)]

    argv = argv ++ model_argv(model)
    argv = argv ++ agent_argv(agent_id)

    # Append any extra argv from acpx config
    argv ++ acpx.extra_argv
  end

  defp permission_flag(agent_config, acpx) do
    permissions = Map.get(agent_config, "permissions", %{})

    case Map.get(agent_config, "permission_mode") || Map.get(permissions, "mode") || acpx.approve_mode do
      "approve-all" -> "--approve-all"
      "approve-reads" -> "--approve-reads"
      "ask" -> "--ask"
      "deny" -> "--deny"
      _ -> "--approve-all"
    end
  end

  defp model_argv(%{"enabled" => true, "config_key" => key, "value" => value})
       when is_binary(key) and key != "" and is_binary(value) and value != "" do
    ["--config", "#{key}=#{value}"]
  end

  defp model_argv(_model), do: []

  defp agent_argv(agent_id) do
    agent_config = Config.agent_config(agent_id) || %{}

    case Map.get(agent_config, "custom_acpx_agent_command") do
      custom when is_binary(custom) and custom != "" ->
        ["--agent", custom]

      _ ->
        [agent_argument(agent_id)]
    end
  end

  defp agent_argument(agent_id) do
    agent_config = Config.agent_config(agent_id) || %{}
    Map.get(agent_config, "acpx_agent", agent_id)
  end
end
