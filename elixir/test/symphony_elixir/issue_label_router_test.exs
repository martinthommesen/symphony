defmodule SymphonyElixir.IssueLabelRouterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.IssueLabelRouter

  describe "resolve/1" do
    test "returns default agent when no matching labels" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          label_prefix: "symphony/agent/",
          default_agent: "backend"
        },
        agents_registry: %{
          backend: %{enabled: true}
        }
      )

      issue = %{labels: ["other"]}
      assert {:ok, "backend", ["other"]} = IssueLabelRouter.resolve(issue)
    end

    test "returns error for unsupported default agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          label_prefix: "symphony/agent/",
          default_agent: "missing"
        }
      )

      issue = %{labels: ["other"]}
      assert {:error, {:unsupported_agent, "missing"}} = IssueLabelRouter.resolve(issue)
    end

    test "resolves namespaced label to agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          label_prefix: "symphony/agent/"
        },
        agents_registry: %{
          backend: %{enabled: true}
        }
      )

      issue = %{labels: ["symphony/agent/backend"]}
      assert {:ok, "backend", ["symphony/agent/backend"]} = IssueLabelRouter.resolve(issue)
    end

    test "resolves bare alias to agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          label_prefix: "symphony/agent/",
          aliases: %{"ai" => "backend"}
        },
        agents_registry: %{
          backend: %{enabled: true}
        }
      )

      issue = %{labels: ["ai"]}
      assert {:ok, "backend", ["ai"]} = IssueLabelRouter.resolve(issue)
    end

    test "namespaced label wins over bare alias" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          label_prefix: "symphony/agent/",
          aliases: %{"ai" => "frontend"}
        },
        agents_registry: %{
          backend: %{enabled: true},
          frontend: %{enabled: true}
        }
      )

      issue = %{labels: ["ai", "symphony/agent/backend"]}
      assert {:ok, "backend", ["ai", "symphony/agent/backend"]} = IssueLabelRouter.resolve(issue)
    end

    test "returns ambiguous agents error for multiple matching labels" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          label_prefix: "symphony/agent/"
        },
        agents_registry: %{
          backend: %{enabled: true},
          frontend: %{enabled: true}
        }
      )

      issue = %{labels: ["symphony/agent/backend", "symphony/agent/frontend"]}
      assert {:error, {:ambiguous_agents, ["backend", "frontend"]}} = IssueLabelRouter.resolve(issue)
    end

    test "returns blocked error for blocked labels" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          blocked_labels: ["symphony/blocked"]
        },
        agents_registry: %{}
      )

      issue = %{labels: ["symphony/blocked"]}
      assert {:error, :blocked} = IssueLabelRouter.resolve(issue)
    end

    test "returns running error for running label" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          running_label: "symphony/running"
        },
        agents_registry: %{}
      )

      issue = %{labels: ["symphony/running"]}
      assert {:error, :running} = IssueLabelRouter.resolve(issue)
    end

    test "returns review error for review label" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          review_label: "symphony/review"
        },
        agents_registry: %{}
      )

      issue = %{labels: ["symphony/review"]}
      assert {:error, :review} = IssueLabelRouter.resolve(issue)
    end

    test "returns failed error for failed label without retry" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          failed_label: "symphony/failed",
          retry_failed: false
        },
        agents_registry: %{}
      )

      issue = %{labels: ["symphony/failed"]}
      assert {:error, :failed} = IssueLabelRouter.resolve(issue)
    end

    test "allows failed label when retry_failed is true" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          failed_label: "symphony/failed",
          retry_failed: true,
          default_agent: "backend"
        },
        agents_registry: %{
          backend: %{enabled: true}
        }
      )

      issue = %{labels: ["symphony/failed"]}
      assert {:ok, "backend", ["symphony/failed"]} = IssueLabelRouter.resolve(issue)
    end

    test "returns no_dispatch_label error when required label missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          required_dispatch_label: "symphony/dispatch",
          default_agent: ""
        }
      )

      settings = Config.settings!()
      assert settings.agents.routing.required_dispatch_label == "symphony/dispatch"

      issue = %{labels: ["other"]}
      assert {:error, :no_dispatch_label} = IssueLabelRouter.resolve(issue)
    end

    test "returns no_labels error for missing labels" do
      assert {:error, :no_labels} = IssueLabelRouter.resolve(%{})
    end

    test "returns unsupported_agent for disabled agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          label_prefix: "symphony/agent/"
        },
        agents_registry: %{
          backend: %{enabled: false}
        }
      )

      issue = %{labels: ["symphony/agent/backend"]}
      assert {:error, {:unsupported_agent, "backend"}} = IssueLabelRouter.resolve(issue)
    end

    test "returns unsupported_agent for unregistered agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agents_routing: %{
          label_prefix: "symphony/agent/"
        },
        agents_registry: %{}
      )

      issue = %{labels: ["symphony/agent/unknown"]}
      assert {:error, {:unsupported_agent, "unknown"}} = IssueLabelRouter.resolve(issue)
    end
  end
end
