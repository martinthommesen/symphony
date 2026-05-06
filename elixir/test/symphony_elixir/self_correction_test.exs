defmodule SymphonyElixir.SelfCorrectionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SelfCorrection

  describe "classify/1" do
    test "classifies acpx missing" do
      assert SelfCorrection.classify({:acpx_not_found, "acpx"}) == :acpx_missing
    end

    test "classifies acpx session errors" do
      assert SelfCorrection.classify({:acpx_session_error, %{"code" => -32_603, "message" => "startup failed"}}) == :acpx_adapter_error
      assert SelfCorrection.classify({:acpx_session_error, %{"code" => -32_600, "message" => "timeout"}}) == :agent_stalled
      assert SelfCorrection.classify({:acpx_session_error, %{"message" => "generic"}}) == :acpx_session_error
    end

    test "classifies auth missing" do
      assert SelfCorrection.classify({:error, :missing_linear_api_token}) == :auth_missing
    end

    test "classifies config invalid" do
      assert SelfCorrection.classify({:error, {:invalid_workflow_config, "bad"}}) == :config_invalid
    end

    test "classifies ambiguous agents" do
      assert SelfCorrection.classify({:error, {:ambiguous_agents, ["a", "b"]}}) == :ambiguous_agent_labels
    end

    test "classifies unsupported agent" do
      assert SelfCorrection.classify({:error, {:unsupported_agent, "x"}}) == :unsupported_agent
    end

    test "classifies workspace corrupt" do
      assert SelfCorrection.classify({:error, {:path_canonicalize_failed, "/x", :enoent}}) == :workspace_corrupt
    end

    test "classifies acpx session exit" do
      assert SelfCorrection.classify({:acpx_session_exit, :error}) == :acpx_adapter_error
    end

    test "classifies acpx process exit" do
      assert SelfCorrection.classify({:acpx_exit, 12}) == :acpx_adapter_error
    end

    test "classifies acpx session timeout" do
      assert SelfCorrection.classify(:acpx_session_timeout) == :agent_stalled
    end

    test "classifies acpx session error without map" do
      assert SelfCorrection.classify({:acpx_session_error, :error}) == :acpx_session_error
    end

    test "classifies missing project slug as config invalid" do
      assert SelfCorrection.classify({:error, :missing_linear_project_slug}) == :config_invalid
    end

    test "classifies unsupported tracker kind as config invalid" do
      assert SelfCorrection.classify({:error, {:unsupported_tracker_kind, "jira"}}) == :config_invalid
    end

    test "classifies no dispatch label as unsupported agent" do
      assert SelfCorrection.classify({:error, :no_dispatch_label}) == :unsupported_agent
    end

    test "classifies no labels as unsupported agent" do
      assert SelfCorrection.classify({:error, :no_labels}) == :unsupported_agent
    end

    test "classifies blocked/running/review/failed as skip" do
      assert SelfCorrection.classify({:error, :blocked}) == :skip
      assert SelfCorrection.classify({:error, :running}) == :skip
      assert SelfCorrection.classify({:error, :review}) == :skip
      assert SelfCorrection.classify({:error, :failed}) == :skip
    end

    test "classifies runtime errors by message content" do
      assert SelfCorrection.classify(%RuntimeError{message: "agent stalled for 5m"}) == :agent_stalled
      assert SelfCorrection.classify(%RuntimeError{message: "agent cancelled by user"}) == :agent_cancelled
      assert SelfCorrection.classify(%RuntimeError{message: "something else"}) == :unknown_failure
    end

    test "defaults to unknown_failure" do
      assert SelfCorrection.classify(:something_else) == :unknown_failure
    end
  end

  describe "recover/2" do
    defp sc_config(overrides \\ %{}) do
      Map.merge(
        %{
          enabled: true,
          max_correction_attempts: 2,
          retry_backoff_ms: 5_000,
          retry_on_stall: true,
          retry_on_acpx_crash: true,
          retry_on_validation_failure: true,
          retry_on_no_changes: true,
          retry_on_pr_creation_failure: true,
          retry_on_merge_conflict: true,
          retry_on_dependency_missing: true
        },
        Map.new(overrides)
      )
    end

    test "fails when self-correction is disabled" do
      ctx = context(attempt: 1)
      assert {:fail, "self-correction disabled"} = SelfCorrection.recover(:unknown_failure, ctx, sc_config(enabled: false))
    end

    test "fails when max attempts reached" do
      ctx = context(attempt: 3)
      assert {:fail, "max correction attempts (2) reached"} = SelfCorrection.recover(:unknown_failure, ctx, sc_config())
    end

    test "retries acpx crash when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:acpx_adapter_error, ctx, sc_config())
      assert opts[:backoff] == 5_000
    end

    test "fails acpx crash when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:acpx_adapter_error, ctx, sc_config(retry_on_acpx_crash: false))
    end

    test "retries stall when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:agent_stalled, ctx, sc_config())
      assert opts[:cancel_session] == true
    end

    test "fails auth missing immediately" do
      ctx = context(attempt: 1)
      assert {:fail, "auth missing: requires operator action"} = SelfCorrection.recover(:auth_missing, ctx, sc_config())
    end

    test "fails ambiguous labels immediately" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:ambiguous_agent_labels, ctx, sc_config())
    end

    test "retries validation failure with corrective prompt" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:validation_failed, ctx, sc_config())
      assert opts[:corrective_prompt] == true
    end

    test "retries workspace corrupt with fresh workspace" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:workspace_corrupt, ctx, sc_config())
      assert opts[:fresh_workspace] == true
    end

    test "retries unknown failure within attempt budget" do
      ctx = context(attempt: 1)
      assert {:retry, _, _} = SelfCorrection.recover(:unknown_failure, ctx, sc_config())
    end

    test "fails unknown failure at max attempts" do
      ctx = context(attempt: 2)
      assert {:fail, "unknown failure: max attempts reached"} = SelfCorrection.recover(:unknown_failure, ctx, sc_config())
    end

    test "retries dependency missing when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, _} = SelfCorrection.recover(:dependency_missing, ctx, sc_config())
    end

    test "fails dependency missing when disabled" do
      ctx = context(attempt: 1)
      config = sc_config(retry_on_dependency_missing: false)
      assert {:fail, _} = SelfCorrection.recover(:dependency_missing, ctx, config)
    end

    test "retries acpx missing when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, _} = SelfCorrection.recover(:acpx_missing, ctx, sc_config())
    end

    test "fails acpx missing when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:acpx_missing, ctx, sc_config(retry_on_acpx_crash: false))
    end

    test "retries acpx session error when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, _} = SelfCorrection.recover(:acpx_session_error, ctx, sc_config())
    end

    test "fails acpx session error when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:acpx_session_error, ctx, sc_config(retry_on_acpx_crash: false))
    end

    test "fails agent cancelled immediately" do
      ctx = context(attempt: 1)
      assert {:fail, "agent cancelled: not retrying cancellation"} = SelfCorrection.recover(:agent_cancelled, ctx, sc_config())
    end

    test "retries tests failed with corrective prompt" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:tests_failed, ctx, sc_config())
      assert opts[:corrective_prompt] == true
    end

    test "fails tests failed when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:tests_failed, ctx, sc_config(retry_on_validation_failure: false))
    end

    test "retries no changes when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:no_changes, ctx, sc_config())
      assert opts[:corrective_prompt] == true
    end

    test "fails no changes when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:no_changes, ctx, sc_config(retry_on_no_changes: false))
    end

    test "fails no commit immediately" do
      ctx = context(attempt: 1)
      assert {:fail, "no commit: not retrying"} = SelfCorrection.recover(:no_commit, ctx, sc_config())
    end

    test "retries dirty worktree with stash" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:dirty_worktree, ctx, sc_config())
      assert opts[:stash] == true
    end

    test "retries branch conflict when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:branch_conflict, ctx, sc_config())
      assert opts[:rebase] == true
    end

    test "fails branch conflict when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:branch_conflict, ctx, sc_config(retry_on_merge_conflict: false))
    end

    test "retries push failed with fetch" do
      ctx = context(attempt: 1)
      assert {:retry, _, opts} = SelfCorrection.recover(:push_failed, ctx, sc_config())
      assert opts[:fetch] == true
    end

    test "retries pr create failed when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, _} = SelfCorrection.recover(:pr_create_failed, ctx, sc_config())
    end

    test "fails pr create failed when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:pr_create_failed, ctx, sc_config(retry_on_pr_creation_failure: false))
    end

    test "retries pr update failed when enabled" do
      ctx = context(attempt: 1)
      assert {:retry, _, _} = SelfCorrection.recover(:pr_update_failed, ctx, sc_config())
    end

    test "fails pr update failed when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:pr_update_failed, ctx, sc_config(retry_on_pr_creation_failure: false))
    end

    test "fails unsupported agent immediately" do
      ctx = context(attempt: 1)
      assert {:fail, "unsupported agent: add failed label and comment"} = SelfCorrection.recover(:unsupported_agent, ctx, sc_config())
    end

    test "fails config invalid immediately" do
      ctx = context(attempt: 1)
      assert {:fail, "invalid config: fix .symphony/config.yml"} = SelfCorrection.recover(:config_invalid, ctx, sc_config())
    end

    test "fails unclassified failure" do
      ctx = context(attempt: 1)
      assert {:fail, "unclassified failure: not retrying"} = SelfCorrection.recover(:some_random_failure, ctx, sc_config())
    end

    test "fails validation failed when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:validation_failed, ctx, sc_config(retry_on_validation_failure: false))
    end

    test "fails agent stalled when disabled" do
      ctx = context(attempt: 1)
      assert {:fail, _} = SelfCorrection.recover(:agent_stalled, ctx, sc_config(retry_on_stall: false))
    end
  end

  describe "build_corrective_prompt/4" do
    test "includes failure details for validation_failed" do
      ctx = context(attempt: 1)

      prompt =
        SelfCorrection.build_corrective_prompt(
          "original",
          :validation_failed,
          ctx,
          command: "mix test",
          exit_code: 1,
          logs: "1 test failed"
        )

      assert prompt =~ "original"
      assert prompt =~ "validation_failed"
      assert prompt =~ "mix test"
      assert prompt =~ "1 test failed"
    end

    test "includes failure details for tests_failed" do
      ctx = context(attempt: 1)

      prompt =
        SelfCorrection.build_corrective_prompt(
          "original",
          :tests_failed,
          ctx,
          command: "mix test",
          exit_code: 1,
          logs: "1 test failed"
        )

      assert prompt =~ "tests_failed"
      assert prompt =~ "1 test failed"
    end

    test "includes failure details for no_changes" do
      ctx = context(attempt: 1)

      prompt =
        SelfCorrection.build_corrective_prompt(
          "original",
          :no_changes,
          ctx,
          []
        )

      assert prompt =~ "no_changes"
      assert prompt =~ "original"
    end

    test "includes generic details for other failures" do
      ctx = context(attempt: 1)

      prompt =
        SelfCorrection.build_corrective_prompt(
          "original",
          :unknown_failure,
          ctx,
          []
        )

      assert prompt =~ "unknown_failure"
      assert prompt =~ "Retry after failure: unknown_failure"
    end
  end

  describe "log_recovery_decision/3" do
    test "logs retry decision" do
      ctx = context(attempt: 1)
      result = {:retry, "retrying", [backoff: 5000]}

      assert :ok = SelfCorrection.log_recovery_decision(ctx, :recover, result)
    end

    test "logs fail decision" do
      ctx = context(attempt: 1)
      result = {:fail, "giving up"}

      assert :ok = SelfCorrection.log_recovery_decision(ctx, :recover, result)
    end

    test "logs skip decision" do
      ctx = context(attempt: 1)
      result = {:skip, "skipping"}

      assert :ok = SelfCorrection.log_recovery_decision(ctx, :recover, result)
    end
  end

  defp context(overrides) do
    Map.merge(
      %{
        run_id: "run-1",
        issue_id: "issue-1",
        issue_number: "MT-1",
        issue_labels: ["symphony"],
        selected_agent: "backend",
        acpx_session_name: "session-1",
        workspace_path: "/tmp/ws",
        branch_name: "main",
        failure_class: :unknown_failure,
        attempt: 1
      },
      Map.new(overrides)
    )
  end
end
