defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        {:ok, _apps} = Application.ensure_all_started(:symphony_elixir)

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    if is_nil(Process.whereis(SymphonyElixir.Supervisor)) do
      :ok
    else
      stop_default_http_server_child()
    end
  end

  defp stop_default_http_server_child do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          agent_stall_timeout_ms: 300_000,
          acpx_executable: "acpx",
          agents_required_dispatch_label: "",
          agents_routing: nil,
          agents_registry: nil,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          self_correction_enabled: true,
          self_correction_max_correction_attempts: 2,
          self_correction_retry_backoff_ms: 10_000,
          self_correction_retry_on_acpx_crash: true,
          self_correction_retry_on_stall: true,
          self_correction_retry_on_validation_failure: true,
          self_correction_retry_on_no_changes: true,
          self_correction_retry_on_pr_creation_failure: true,
          self_correction_retry_on_merge_conflict: true,
          self_correction_retry_on_dependency_missing: true,
          validation_commands: [],
          validation_fail_if_no_diff: false,
          validation_include_logs_in_corrective_prompt: true,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    agent_stall_timeout_ms = Keyword.get(config, :agent_stall_timeout_ms)
    acpx_executable = Keyword.get(config, :acpx_executable)
    agents_required_dispatch_label = Keyword.get(config, :agents_required_dispatch_label)
    agents_routing = Keyword.get(config, :agents_routing)
    agents_registry = Keyword.get(config, :agents_registry)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    self_correction_enabled = Keyword.get(config, :self_correction_enabled)
    self_correction_max_correction_attempts = Keyword.get(config, :self_correction_max_correction_attempts)
    self_correction_retry_backoff_ms = Keyword.get(config, :self_correction_retry_backoff_ms)
    self_correction_retry_on_acpx_crash = Keyword.get(config, :self_correction_retry_on_acpx_crash)
    self_correction_retry_on_stall = Keyword.get(config, :self_correction_retry_on_stall)
    self_correction_retry_on_validation_failure = Keyword.get(config, :self_correction_retry_on_validation_failure)
    self_correction_retry_on_no_changes = Keyword.get(config, :self_correction_retry_on_no_changes)
    self_correction_retry_on_pr_creation_failure = Keyword.get(config, :self_correction_retry_on_pr_creation_failure)
    self_correction_retry_on_merge_conflict = Keyword.get(config, :self_correction_retry_on_merge_conflict)
    self_correction_retry_on_dependency_missing = Keyword.get(config, :self_correction_retry_on_dependency_missing)
    validation_commands = Keyword.get(config, :validation_commands)
    validation_fail_if_no_diff = Keyword.get(config, :validation_fail_if_no_diff)
    validation_include_logs_in_corrective_prompt = Keyword.get(config, :validation_include_logs_in_corrective_prompt)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "  stall_timeout_ms: #{yaml_value(agent_stall_timeout_ms)}",
        "agents:",
        "  routing:",
        agents_routing_yaml(
          Map.merge(
            %{"required_dispatch_label" => agents_required_dispatch_label},
            agents_routing || %{}
          )
        ),
        agents_registry_yaml(agents_registry),
        "acpx:",
        "  executable: #{yaml_value(acpx_executable)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        validation_yaml(validation_commands, validation_fail_if_no_diff, validation_include_logs_in_corrective_prompt),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        self_correction_yaml(
          enabled: self_correction_enabled,
          max_correction_attempts: self_correction_max_correction_attempts,
          retry_backoff_ms: self_correction_retry_backoff_ms,
          retry_on_acpx_crash: self_correction_retry_on_acpx_crash,
          retry_on_stall: self_correction_retry_on_stall,
          retry_on_validation_failure: self_correction_retry_on_validation_failure,
          retry_on_no_changes: self_correction_retry_on_no_changes,
          retry_on_pr_creation_failure: self_correction_retry_on_pr_creation_failure,
          retry_on_merge_conflict: self_correction_retry_on_merge_conflict,
          retry_on_dependency_missing: self_correction_retry_on_dependency_missing
        ),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}",
      # The following keys are optional; default to safe values so the
      # event store/control auth modules behave deterministically in tests.
      "  jsonl_enabled: false",
      "  event_buffer_size: 1000"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp agents_routing_yaml(nil), do: nil

  defp agents_routing_yaml(routing) when is_map(routing) do
    Enum.map_join(routing, "\n", fn {key, value} ->
      "    #{key}: #{yaml_value(value)}"
    end)
  end

  defp agents_registry_yaml(nil), do: nil

  defp agents_registry_yaml(registry) when is_map(registry) do
    entries =
      Enum.map_join(registry, "\n", fn {key, value} ->
        "    #{key}: #{yaml_value(value)}"
      end)

    "  registry:\n#{entries}"
  end

  defp self_correction_yaml(opts) when is_list(opts) do
    defaults = [
      enabled: true,
      max_correction_attempts: 2,
      retry_backoff_ms: 5000,
      retry_on_acpx_crash: true,
      retry_on_stall: true,
      retry_on_validation_failure: true,
      retry_on_no_changes: true,
      retry_on_pr_creation_failure: true,
      retry_on_merge_conflict: true,
      retry_on_dependency_missing: true
    ]

    opts = Keyword.merge(defaults, opts)

    [
      "self_correction:",
      "  enabled: #{yaml_value(opts[:enabled])}",
      "  max_correction_attempts: #{yaml_value(opts[:max_correction_attempts])}",
      "  retry_backoff_ms: #{yaml_value(opts[:retry_backoff_ms])}",
      "  retry_on_acpx_crash: #{yaml_value(opts[:retry_on_acpx_crash])}",
      "  retry_on_stall: #{yaml_value(opts[:retry_on_stall])}",
      "  retry_on_validation_failure: #{yaml_value(opts[:retry_on_validation_failure])}",
      "  retry_on_no_changes: #{yaml_value(opts[:retry_on_no_changes])}",
      "  retry_on_pr_creation_failure: #{yaml_value(opts[:retry_on_pr_creation_failure])}",
      "  retry_on_merge_conflict: #{yaml_value(opts[:retry_on_merge_conflict])}",
      "  retry_on_dependency_missing: #{yaml_value(opts[:retry_on_dependency_missing])}"
    ]
    |> Enum.join("\n")
  end

  defp validation_yaml(commands, fail_if_no_diff, include_logs) do
    [
      "validation:",
      "  commands: #{yaml_value(commands)}",
      "  include_logs_in_corrective_prompt: #{yaml_value(include_logs)}",
      "  fail_if_no_diff: #{yaml_value(fail_if_no_diff)}"
    ]
    |> Enum.join("\n")
  end
end
