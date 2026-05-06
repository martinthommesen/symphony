defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string, default: "github")
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      # Defaults are GitHub-shaped because the default tracker is `github`.
      # The orchestrator dispatches issues whose state is in `active_states`
      # and considers `terminal_states` complete. The GitHub adapter emits
      # states like `"open"`, `"running"`, `"review"`, `"failed"`, `"done"`,
      # `"blocked"`, and `"closed"`; only fresh `"open"` issues are eligible
      # to be claimed.
      #
      # Linear backwards-compatible deployments must override these in
      # WORKFLOW.md (`tracker.active_states`, `tracker.terminal_states`).
      field(:active_states, {:array, :string}, default: ["open"])
      field(:terminal_states, {:array, :string}, default: ["closed"])
      field(:repo, :string)
      field(:active_labels, {:array, :string}, default: ["symphony"])
      field(:blocked_labels, {:array, :string}, default: ["symphony/blocked"])
      field(:running_label, :string, default: "symphony/running")
      field(:done_label, :string, default: "symphony/done")
      field(:failed_label, :string, default: "symphony/failed")
      field(:review_label, :string, default: "symphony/review")
      field(:retry_failed, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :active_states,
          :terminal_states,
          :repo,
          :active_labels,
          :blocked_labels,
          :running_label,
          :done_label,
          :failed_label,
          :review_label,
          :retry_failed
        ],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
      field(:worktree_strategy, :string, default: "reuse")
      field(:git_worktree_enabled, :boolean, default: false)
      field(:branch_prefix, :string, default: "symphony/")
      field(:branch_name_template, :string, default: "symphony/issue-{{issue_number}}")
      field(:base_branch, :string, default: "main")
      field(:fetch_before_run, :boolean, default: false)
      field(:rebase_before_run, :boolean, default: false)
      field(:reset_dirty_workspace_policy, :string, default: "fail")
      field(:cleanup_policy, :string, default: "never")
      field(:retention_days, :integer, default: 14)
      field(:max_workspace_size_bytes, :integer)
      field(:prune_stale_workspaces, :boolean, default: false)
      field(:isolate_dependency_caches, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :root,
          :worktree_strategy,
          :git_worktree_enabled,
          :branch_prefix,
          :branch_name_template,
          :base_branch,
          :fetch_before_run,
          :rebase_before_run,
          :reset_dirty_workspace_policy,
          :cleanup_policy,
          :retention_days,
          :max_workspace_size_bytes,
          :prune_stale_workspaces,
          :isolate_dependency_caches
        ],
        empty_values: []
      )
      |> validate_inclusion(:worktree_strategy, ["reuse", "fresh_per_attempt", "reset_before_retry", "preserve_on_failure"])
      |> validate_inclusion(:reset_dirty_workspace_policy, ["fail", "stash", "reset"])
      |> validate_inclusion(:cleanup_policy, ["never", "on_success", "on_done_label", "after_retention"])
      |> validate_number(:retention_days, greater_than: 0)
      |> validate_number(:max_workspace_size_bytes, greater_than: 0)
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state, :stall_timeout_ms],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Acpx do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:executable, :string, default: "acpx")
      field(:pinned_version, :string)
      field(:install_location, :string)
      field(:config_location, :string)
      field(:default_output_format, :string, default: "json")
      field(:json_strict, :boolean, default: true)
      field(:suppress_reads, :boolean, default: true)
      field(:approve_mode, :string, default: "approve-all")
      field(:non_interactive_permission_behavior, :string, default: "deny")
      field(:auth_policy, :string, default: "auto")
      field(:extra_argv, {:array, :string}, default: [])
      field(:custom_agent_definitions, :map, default: %{})
      field(:session_naming_template, :string, default: "symphony-{{issue_number}}")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :executable,
          :pinned_version,
          :install_location,
          :config_location,
          :default_output_format,
          :json_strict,
          :suppress_reads,
          :approve_mode,
          :non_interactive_permission_behavior,
          :auth_policy,
          :extra_argv,
          :custom_agent_definitions,
          :session_naming_template
        ],
        empty_values: []
      )
      |> validate_required([:executable])
      |> validate_inclusion(:default_output_format, ["json", "text"])
      |> validate_inclusion(:approve_mode, ["approve-all", "approve-reads", "ask", "deny"])
      |> validate_inclusion(:non_interactive_permission_behavior, ["deny", "approve", "ignore"])
    end
  end

  defmodule Agents do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    defmodule Routing do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field(:required_dispatch_label, :string, default: "symphony")
        field(:label_prefix, :string, default: "symphony/agent/")
        field(:default_agent, :string, default: "codex")
        field(:multi_agent_policy, :string, default: "reject")
        field(:aliases, :map, default: %{})
        field(:blocked_labels, {:array, :string}, default: [])
        field(:running_label, :string, default: "")
        field(:review_label, :string, default: "")
        field(:failed_label, :string, default: "")
        field(:retry_failed, :boolean, default: false)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        attrs = normalize_legacy_routing_keys(attrs)

        schema
        |> cast(
          attrs,
          [
            :required_dispatch_label,
            :label_prefix,
            :default_agent,
            :multi_agent_policy,
            :aliases,
            :blocked_labels,
            :running_label,
            :review_label,
            :failed_label,
            :retry_failed
          ],
          empty_values: []
        )
        |> validate_inclusion(:multi_agent_policy, ["reject", "fanout_draft_prs", "race_first_success"])
      end

      defp normalize_legacy_routing_keys(attrs) when is_map(attrs) do
        attrs
        |> maybe_copy("required_label_prefix", "label_prefix")
        |> maybe_copy("label_aliases", "aliases")
      end

      defp normalize_legacy_routing_keys(attrs), do: attrs

      defp maybe_copy(attrs, from, to) do
        if Map.has_key?(attrs, from) and not Map.has_key?(attrs, to) do
          Map.put(attrs, to, Map.fetch!(attrs, from))
        else
          attrs
        end
      end
    end

    @primary_key false
    embedded_schema do
      embeds_one(:routing, Routing, on_replace: :update, defaults_to_struct: true)
      field(:registry, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:registry], empty_values: [])
      |> cast_embed(:routing, with: &Routing.changeset/2)
    end
  end

  defmodule Commit do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:strategy, :string, default: "agent_commits")
      field(:message_template, :string)
      field(:author_name, :string)
      field(:author_email, :string)
      field(:sign_commits, :boolean, default: false)
      field(:allow_empty, :boolean, default: false)
      field(:include_untracked, :boolean, default: false)
      field(:max_changed_files, :integer)
      field(:max_diff_size, :integer)
      field(:run_pre_commit_hooks, :boolean, default: false)
      field(:commit_only_after_validation, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :strategy,
          :message_template,
          :author_name,
          :author_email,
          :sign_commits,
          :allow_empty,
          :include_untracked,
          :max_changed_files,
          :max_diff_size,
          :run_pre_commit_hooks,
          :commit_only_after_validation
        ],
        empty_values: []
      )
      |> validate_inclusion(:strategy, ["agent_commits", "symphony_commits_all", "symphony_commits_selected", "no_commit"])
    end
  end

  defmodule PR do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:draft, :boolean, default: false)
      field(:update_existing, :boolean, default: false)
      field(:title_template, :string)
      field(:body_template, :string)
      field(:include_issue_link, :boolean, default: true)
      field(:reviewers, {:array, :string}, default: [])
      field(:team_reviewers, {:array, :string}, default: [])
      field(:assignees, {:array, :string}, default: [])
      field(:labels, {:array, :string}, default: [])
      field(:milestone, :string)
      field(:request_review, :boolean, default: false)
      field(:auto_merge, :boolean, default: false)
      field(:close_issue_on_merge, :boolean, default: false)
      field(:comment_on_issue, :boolean, default: true)
      field(:include_logs_summary, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :draft,
          :update_existing,
          :title_template,
          :body_template,
          :include_issue_link,
          :reviewers,
          :team_reviewers,
          :assignees,
          :labels,
          :milestone,
          :request_review,
          :auto_merge,
          :close_issue_on_merge,
          :comment_on_issue,
          :include_logs_summary
        ],
        empty_values: []
      )
    end
  end

  defmodule Validation do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:commands, {:array, :string}, default: [])
      field(:test_command, :string)
      field(:typecheck_command, :string)
      field(:lint_command, :string)
      field(:max_retries, :integer, default: 0)
      field(:include_logs_in_corrective_prompt, :boolean, default: false)
      field(:fail_if_no_diff, :boolean, default: false)
      field(:fail_if_no_commit, :boolean, default: false)
      field(:fail_if_pr_cannot_be_created, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :commands,
          :test_command,
          :typecheck_command,
          :lint_command,
          :max_retries,
          :include_logs_in_corrective_prompt,
          :fail_if_no_diff,
          :fail_if_no_commit,
          :fail_if_pr_cannot_be_created
        ],
        empty_values: []
      )
      |> validate_number(:max_retries, greater_than_or_equal_to: 0)
    end
  end

  defmodule SelfCorrection do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:max_correction_attempts, :integer, default: 2)
      field(:correction_prompt_template, :string)
      field(:retry_backoff_ms, :integer, default: 10_000)
      field(:classify_failures, :boolean, default: true)
      field(:retry_on_stall, :boolean, default: true)
      field(:retry_on_acpx_crash, :boolean, default: true)
      field(:retry_on_validation_failure, :boolean, default: true)
      field(:retry_on_no_changes, :boolean, default: true)
      field(:retry_on_pr_creation_failure, :boolean, default: true)
      field(:retry_on_merge_conflict, :boolean, default: true)
      field(:retry_on_dependency_missing, :boolean, default: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :max_correction_attempts,
          :correction_prompt_template,
          :retry_backoff_ms,
          :classify_failures,
          :retry_on_stall,
          :retry_on_acpx_crash,
          :retry_on_validation_failure,
          :retry_on_no_changes,
          :retry_on_pr_creation_failure,
          :retry_on_merge_conflict,
          :retry_on_dependency_missing
        ],
        empty_values: []
      )
      |> validate_number(:max_correction_attempts, greater_than_or_equal_to: 0)
      |> validate_number(:retry_backoff_ms, greater_than: 0)
    end
  end

  defmodule Logging do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:level, :string, default: "info")
      field(:directory, :string)
      field(:ndjson_enabled, :boolean, default: true)
      field(:text_logs_enabled, :boolean, default: false)
      field(:event_retention_days, :integer, default: 30)
      field(:redact_secrets, :boolean, default: true)
      field(:raw_acpx_event_capture, :boolean, default: false)
      field(:raw_stdout_stderr_capture, :boolean, default: false)
      field(:max_log_size_bytes, :integer)
      field(:compress_old_logs, :boolean, default: false)
      field(:tui_audit_log, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :level,
          :directory,
          :ndjson_enabled,
          :text_logs_enabled,
          :event_retention_days,
          :redact_secrets,
          :raw_acpx_event_capture,
          :raw_stdout_stderr_capture,
          :max_log_size_bytes,
          :compress_old_logs,
          :tui_audit_log
        ],
        empty_values: []
      )
      |> validate_inclusion(:level, ["debug", "info", "warning", "error"])
      |> validate_number(:event_retention_days, greater_than: 0)
    end
  end

  defmodule Finalizer do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:auto_commit_uncommitted, :boolean, default: true)
      field(:push_branch, :boolean, default: true)
      field(:open_pr, :boolean, default: true)
      field(:close_issue, :boolean, default: false)
      field(:merge_pr, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:auto_commit_uncommitted, :push_branch, :open_pr, :close_issue, :merge_pr],
        empty_values: []
      )
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
      field(:event_buffer_size, :integer, default: 5_000)
      field(:jsonl_enabled, :boolean, default: true)
      field(:jsonl_path, :string, default: ".symphony/logs/events.jsonl")
      field(:control_token_file, :string, default: ".symphony/control-token")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :dashboard_enabled,
          :refresh_ms,
          :render_interval_ms,
          :event_buffer_size,
          :jsonl_enabled,
          :jsonl_path,
          :control_token_file
        ],
        empty_values: []
      )
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
      |> validate_number(:event_buffer_size, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:acpx, Acpx, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agents, Agents, on_replace: :update, defaults_to_struct: true)
    embeds_one(:commit, Commit, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pr, PR, on_replace: :update, defaults_to_struct: true)
    embeds_one(:validation, Validation, on_replace: :update, defaults_to_struct: true)
    embeds_one(:self_correction, SelfCorrection, on_replace: :update, defaults_to_struct: true)
    embeds_one(:logging, Logging, on_replace: :update, defaults_to_struct: true)
    embeds_one(:finalizer, Finalizer, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:acpx, with: &Acpx.changeset/2)
    |> cast_embed(:agents, with: &Agents.changeset/2)
    |> cast_embed(:commit, with: &Commit.changeset/2)
    |> cast_embed(:pr, with: &PR.changeset/2)
    |> cast_embed(:validation, with: &Validation.changeset/2)
    |> cast_embed(:self_correction, with: &SelfCorrection.changeset/2)
    |> cast_embed(:logging, with: &Logging.changeset/2)
    |> cast_embed(:finalizer, with: &Finalizer.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    agents = %{
      settings.agents
      | registry: normalize_agent_registry(settings.agents.registry)
    }

    %{settings | tracker: tracker, workspace: workspace, agents: agents}
  end

  defp normalize_agent_registry(nil), do: default_agent_registry()
  defp normalize_agent_registry(registry) when map_size(registry) == 0, do: default_agent_registry()

  defp normalize_agent_registry(registry) when is_map(registry) do
    registry
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_keys(v)} end)
    |> Enum.into(%{})
  end

  defp default_agent_registry do
    [
      {"codex", "Codex", "codex", true, "warn"},
      {"claude", "Claude", "claude", true, "warn"},
      {"copilot", "Copilot", "copilot", true, "warn"},
      {"gemini", "Gemini", "gemini", true, "warn"},
      {"cursor", "Cursor", "cursor", true, "warn"},
      {"opencode", "OpenCode", "opencode", true, "warn"},
      {"qwen", "Qwen", "qwen", true, "warn"},
      {"custom", "Custom ACP Agent", nil, false, "ignore"}
    ]
    |> Enum.map(fn {id, display_name, acpx_agent, enabled, on_unsupported} ->
      {id, default_agent_entry(id, display_name, acpx_agent, enabled, on_unsupported)}
    end)
    |> Enum.into(%{})
  end

  defp default_agent_entry(id, display_name, acpx_agent, enabled, on_unsupported) do
    %{
      "enabled" => enabled,
      "display_name" => display_name,
      "issue_label" => "symphony/agent/#{id}",
      "acpx_agent" => acpx_agent,
      "custom_acpx_agent_command" => nil,
      "model" => %{
        "enabled" => false,
        "config_key" => "model",
        "value" => nil,
        "on_unsupported" => on_unsupported
      },
      "permissions" => %{
        "mode" => if(id == "custom", do: "approve-reads", else: "approve-all"),
        "non_interactive" => "deny"
      },
      "runtime" => %{
        "timeout_seconds" => 3600,
        "ttl_seconds" => 300,
        "max_attempts" => if(id == "custom", do: 2, else: 3),
        "max_correction_attempts" => if(id == "custom", do: 1, else: 2)
      },
      "prerequisites" => %{
        "checks" => prerequisite_checks(id)
      }
    }
  end

  defp prerequisite_checks("custom"), do: []

  defp prerequisite_checks(id) do
    command = if(id == "cursor", do: "cursor-agent", else: id)

    [
      %{
        "command" => command,
        "args" => ["--version"],
        "kind" => "agent_prerequisite_check"
      }
    ]
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
