defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{Comment, CommentSteering}

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "Symphony issue workspace initialized"
    assert Map.get(hooks, "before_remove") =~ "true"

    linear_agent = Map.get(config, "linear_agent", %{})
    assert Map.get(linear_agent, "enabled") == true
    assert Map.get(linear_agent, "repo_roots") == ["/Users/konark/code"]
    assert "Blocked" in Map.get(linear_agent, "required_statuses")

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid, 15_000)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid, 15_000)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "human review issue state parks running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-human-review-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-review"
    issue_identifier = "MT-560"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "Human Review", "Rework", "Merging"],
        tracker_terminal_states: ["Done", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Human Review",
        title: "Ready for review",
        description: "Should park the worker",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "human review comment worker stays running while issue remains in review" do
    issue_id = "issue-review-worker"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          mode: :review_comment,
          identifier: "MT-562",
          issue: %Issue{id: issue_id, state: "Human Review", identifier: "MT-562"},
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "Human Review",
      title: "Review comment run",
      description: "Review worker should keep interpreting comments",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert Process.alive?(agent_pid)

    send(agent_pid, :stop)
  end

  test "linear agent worker stays running when prompted from human review" do
    issue_id = "issue-linear-agent-review-worker"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          mode: :linear_agent,
          identifier: "MT-563",
          issue: %Issue{id: issue_id, state: "Human Review", identifier: "MT-563"},
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-563",
      state: "Human Review",
      title: "Review prompt run",
      description: "Linear Agent worker should keep handling a review prompt",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert Process.alive?(agent_pid)

    send(agent_pid, :stop)
  end

  test "completed human review comment worker releases claim without continuation retry" do
    issue_id = "issue-review-complete"
    monitor_ref = make_ref()

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: monitor_ref,
          mode: :review_comment,
          identifier: "MT-564",
          issue: %Issue{id: issue_id, state: "Human Review", identifier: "MT-564"},
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:DOWN, monitor_ref, :process, self(), :normal}, state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "comments during an active human review worker queue exactly one follow-up run" do
    {:ok, status_time, _offset} = DateTime.from_iso8601("2026-04-28T01:00:00Z")
    {:ok, comment_time, _offset} = DateTime.from_iso8601("2026-04-28T01:01:00Z")

    issue = %Issue{
      id: "issue-review-queue",
      identifier: "MT-565",
      state: "Human Review",
      title: "Queue review comments",
      description: "Should queue comments that arrive during a review run",
      labels: []
    }

    status_comment = %Comment{
      id: "status",
      body:
        CommentSteering.build_status_body(issue, %{
          last_seen_comment_id: "status",
          last_seen_comment_updated_at: DateTime.to_iso8601(status_time)
        }),
      created_at: status_time,
      updated_at: status_time,
      author_name: "Symphony"
    }

    human_comment = %Comment{
      id: "comment-queued",
      body: "One more review note while you are already looking.",
      created_at: comment_time,
      updated_at: comment_time,
      author_name: "Konark"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue.id => [status_comment, human_comment]
    })

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    monitor_ref = make_ref()

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: self(),
          ref: monitor_ref,
          mode: :review_comment,
          identifier: issue.identifier,
          issue: issue,
          pending_review_comments: [],
          pending_steering_comments: [],
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    updated_state = Orchestrator.poll_comment_steering_for_test(state)

    assert_receive {:memory_tracker_comment_reaction, "comment-queued", "eyes"}
    assert_receive {:memory_tracker_comment_update, "status", updated_status}
    assert updated_status =~ "comment-queued"

    assert %{pending_review_comments: [^human_comment], pending_steering_comments: [_message]} =
             updated_state.running[issue.id]

    assert {:noreply, completed_state} =
             Orchestrator.handle_info({:DOWN, monitor_ref, :process, self(), :normal}, updated_state)

    assert %{
             mode: :review_comment,
             pending_review_comments: [^human_comment],
             attempt: 1
           } = completed_state.retry_attempts[issue.id]

    refute Map.has_key?(completed_state.running, issue.id)
  end

  test "human review comments are acknowledged and queued for a review worker when slots are full" do
    {:ok, status_time, _offset} = DateTime.from_iso8601("2026-04-28T01:00:00Z")
    {:ok, comment_time, _offset} = DateTime.from_iso8601("2026-04-28T01:01:00Z")

    issue = %Issue{
      id: "issue-human-review-comments",
      identifier: "MT-563",
      state: "Human Review",
      title: "Review comments",
      description: "Should be watched while parked",
      labels: []
    }

    marker = %{
      last_seen_comment_id: "status",
      last_seen_comment_updated_at: DateTime.to_iso8601(status_time)
    }

    status_comment = %Comment{
      id: "status",
      body: CommentSteering.build_status_body(issue, marker),
      created_at: status_time,
      updated_at: status_time,
      author_name: "Symphony"
    }

    human_comment = %Comment{
      id: "comment-new",
      body: "Can you take another look?",
      created_at: comment_time,
      updated_at: comment_time,
      author_name: "Konark"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue.id => [status_comment, human_comment]
    })

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Human Review", "Rework", "Merging"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 0,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    updated_state = Orchestrator.poll_comment_steering_for_test(state)

    assert_receive {:memory_tracker_comment_reaction, "comment-new", "eyes"}
    assert_receive {:memory_tracker_comment_update, "status", updated_status}
    assert updated_status =~ "Saw a worker-routed Linear comment."
    assert updated_status =~ "comment-new"

    assert %{
             mode: :review_comment,
             pending_review_comments: [^human_comment],
             pending_steering_comments: [_message]
           } = updated_state.retry_attempts[issue.id]
  end

  test "explicit bridge commands get eyes, threaded replies, and do not wake workers" do
    {:ok, status_time, _offset} = DateTime.from_iso8601("2026-04-28T01:00:00Z")
    {:ok, command_time, _offset} = DateTime.from_iso8601("2026-04-28T01:01:00Z")

    issue = %Issue{
      id: "issue-command",
      identifier: "MT-566",
      state: "Human Review",
      title: "Command issue",
      description: "Bridge commands should stay in the bridge layer",
      labels: []
    }

    status_comment = %Comment{
      id: "status",
      body:
        CommentSteering.build_status_body(issue, %{
          last_seen_comment_id: "status",
          last_seen_comment_updated_at: DateTime.to_iso8601(status_time)
        }),
      created_at: status_time,
      updated_at: status_time,
      author_name: "Symphony"
    }

    command_comment = %Comment{
      id: "command-status",
      body: "symphony status",
      created_at: command_time,
      updated_at: command_time,
      author_name: "Konark"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue.id => [status_comment, command_comment]})
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Human Review", "Rework", "Merging"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    updated_state = Orchestrator.poll_comment_steering_for_test(state)

    assert_receive {:memory_tracker_comment_reaction, "command-status", "eyes"}
    issue_id = issue.id
    assert_receive {:memory_tracker_comment_reply, ^issue_id, "command-status", reply}
    assert reply =~ "Status: Human Review"
    assert_receive {:memory_tracker_comment_update, "status", updated_status}
    assert updated_status =~ "command-status"
    assert updated_status =~ ~s("last_command":"status")

    refute Map.has_key?(updated_state.running, issue.id)
    refute Map.has_key?(updated_state.retry_attempts, issue.id)
    assert %{command: "status", issue_identifier: "MT-566"} = updated_state.last_bridge_command
  end

  test "pause suppresses non-command review routing until resume command clears marker" do
    {:ok, status_time, _offset} = DateTime.from_iso8601("2026-04-28T01:00:00Z")
    {:ok, comment_time, _offset} = DateTime.from_iso8601("2026-04-28T01:01:00Z")

    issue = %Issue{
      id: "issue-paused-command",
      identifier: "MT-567",
      state: "Human Review",
      title: "Paused issue",
      description: "Paused comments should not route",
      labels: []
    }

    paused_marker = %{
      last_seen_comment_id: "status",
      last_seen_comment_updated_at: DateTime.to_iso8601(status_time),
      paused: true,
      last_command: "pause",
      last_command_comment_id: "pause-comment",
      last_command_at: DateTime.to_iso8601(status_time)
    }

    status_comment = %Comment{
      id: "status",
      body: CommentSteering.build_status_body(issue, paused_marker),
      created_at: status_time,
      updated_at: status_time,
      author_name: "Symphony"
    }

    human_comment = %Comment{
      id: "comment-while-paused",
      body: "Please make this change after all.",
      created_at: comment_time,
      updated_at: comment_time,
      author_name: "Konark"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue.id => [status_comment, human_comment]})
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Human Review", "Rework", "Merging"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    updated_state = Orchestrator.poll_comment_steering_for_test(state)

    assert_receive {:memory_tracker_comment_reaction, "comment-while-paused", "eyes"}
    assert_receive {:memory_tracker_comment_update, "status", paused_status}
    assert paused_status =~ ~s("paused":true)
    refute_receive {:memory_tracker_comment_reply, _, _, _}, 50
    refute Map.has_key?(updated_state.running, issue.id)
    refute Map.has_key?(updated_state.retry_attempts, issue.id)

    {:ok, resume_time, _offset} = DateTime.from_iso8601("2026-04-28T01:02:00Z")

    resume_comment = %Comment{
      id: "resume-command",
      body: "symphony resume",
      created_at: resume_time,
      updated_at: resume_time,
      author_name: "Konark"
    }

    status_after_pause = %Comment{
      status_comment
      | body: paused_status,
        updated_at: comment_time
    }

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue.id => [status_after_pause, human_comment, resume_comment]})

    resumed_state = Orchestrator.poll_comment_steering_for_test(state)

    assert_receive {:memory_tracker_comment_reaction, "resume-command", "eyes"}
    issue_id = issue.id
    assert_receive {:memory_tracker_comment_reply, ^issue_id, "resume-command", resume_reply}
    assert resume_reply =~ "Resumed"
    assert_receive {:memory_tracker_comment_update, "status", resumed_status}
    assert resumed_status =~ ~s("paused":false)
    refute Map.has_key?(resumed_state.retry_attempts, issue.id)
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, -1_000, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 37_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 7_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid, 15_000).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are Symphony, a lightweight coworker operating from Linear."
    assert prompt =~ "Ticket: `MT-616`"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "State: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "Do not create or maintain a persistent `## Symphony Status` comment"
    assert prompt =~ "## End-of-Turn Contract"
    assert prompt =~ "The final assistant message is internal to Symphony logs/dashboard"
    assert prompt =~ "Do not duplicate the user-facing Linear response in the final assistant message"
    assert prompt =~ "Natural approval comments do not trigger merging in this MVP"
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "do not call `gh pr merge` directly"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner adds Linear Agent end-of-turn contract" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-linear-agent-prompt-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-linear-agent"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-linear-agent-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        prompt: "Base issue prompt for {{ issue.identifier }}"
      )

      issue = %Issue{
        id: "issue-linear-agent",
        identifier: "MT-251",
        title: "Answer in Linear",
        description: "Simple question",
        state: "In Progress",
        url: "https://example.org/issues/MT-251",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 linear_agent: true,
                 agent_session_id: "agent-session-251"
               )

      turn_text =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "turn/start"))
        |> get_in(["params", "input"])
        |> Enum.map_join("\n", &Map.get(&1, "text", ""))

      assert turn_text =~ "Base issue prompt for MT-251"
      assert turn_text =~ "Linear Agent mode:"
      assert turn_text =~ "The final assistant message is internal to Symphony logs/dashboard"
      assert turn_text =~ "not the Linear-facing response"
      assert turn_text =~ "Do not duplicate the user-facing Linear response there"
      assert turn_text =~ "Do not change state just because the AgentSession started or because you answered a conversational prompt"
      assert turn_text =~ "Classify direct questions before changing state"
      assert turn_text =~ "If the issue or current prompt delegates the question itself as the task"
      assert turn_text =~ "If the issue already represents broader work"
      assert turn_text =~ "leave state unchanged unless you actually begin/change task execution or become blocked"
      assert turn_text =~ "When you begin real implementation or task execution on an unstarted issue, move it to `In Progress`"
      assert turn_text =~ "For ready handoff after real work, move it to `Human Review`"
      assert turn_text =~ "Agent session id: agent-session-251"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "linear agent prompted event steers a starting issue room instead of dispatching duplicate worker" do
    issue = %Issue{
      id: "issue-linear-agent-starting",
      identifier: "MT-252",
      title: "Starting room",
      description: "Prompt while the first turn is still starting",
      state: "In Progress",
      url: "https://example.org/issues/MT-252",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      linear_agent_enabled: true
    )

    orchestrator_name = Module.concat(__MODULE__, :LinearAgentStartingRoomOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)
    worker_ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: worker_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      thread_id: "thread-existing",
      active_turn_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now(),
      mode: :linear_agent
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
    end)

    Orchestrator.handle_agent_session_event(
      %{
        action: "prompted",
        agent_session_id: "agent-session-252",
        prompt_body: "Please make the small review change.",
        prompt_context: nil,
        issue: issue
      },
      orchestrator_name
    )

    assert_receive {:symphony_steer, steering_prompt}, 1_000
    assert steering_prompt =~ "Linear AgentSession event: prompted"
    assert steering_prompt =~ "Please make the small review change."

    updated_state = :sys.get_state(pid, 15_000)
    assert Map.keys(updated_state.running) == [issue.id]
    assert updated_state.running[issue.id].pid == self()
    assert updated_state.running[issue.id].ref == worker_ref
  end

  test "linear agent created event starts delegated backlog issue without bridge-owned state change" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-backlog-start-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"id":1'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-backlog-start"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-backlog-start"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-linear-agent-backlog-start",
        identifier: "MT-260",
        title: "Backlog delegated issue",
        description: "10*2.5",
        state: "Backlog",
        url: "https://example.org/issues/MT-260",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        linear_agent_enabled: true,
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        prompt: "Base issue prompt for {{ issue.identifier }}"
      )

      orchestrator_name = Module.concat(__MODULE__, :LinearAgentBacklogStartOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        System.delete_env("SYMP_TEST_CODEx_TRACE")
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
        File.rm_rf(test_root)
      end)

      Orchestrator.handle_agent_session_event(
        %{
          action: "created",
          agent_session_id: "agent-session-260",
          prompt_body: nil,
          prompt_context: "<issue identifier=\"MT-260\"><title>Backlog delegated issue</title></issue>",
          issue: issue
        },
        orchestrator_name
      )

      eventually(
        fn ->
          trace = if File.exists?(trace_file), do: File.read!(trace_file), else: ""
          assert trace =~ "\"method\":\"initialize\""
        end,
        80
      )

      refute_received {:memory_tracker_state_update, "issue-linear-agent-backlog-start", _state}
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      File.rm_rf(test_root)
    end
  end

  test "linear agent issue status event starts issue in action state without bridge-owned state change" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-status-start-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"id":1'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-status-start"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-status-start"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-linear-agent-status-start",
        identifier: "MT-261",
        title: "In Progress delegated issue",
        description: "10*2.5",
        state: "In Progress",
        url: "https://example.org/issues/MT-261",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        linear_agent_enabled: true,
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        prompt: "Base issue prompt for {{ issue.identifier }}"
      )

      orchestrator_name = Module.concat(__MODULE__, :LinearAgentStatusStartOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        System.delete_env("SYMP_TEST_CODEx_TRACE")
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
        File.rm_rf(test_root)
      end)

      Orchestrator.handle_agent_session_event(
        %{
          action: "issueStatusChanged",
          agent_session_id: "agent-session-261",
          prompt_body: nil,
          prompt_context: "<issue identifier=\"MT-261\"><title>Backlog delegated issue</title></issue>",
          issue: issue
        },
        orchestrator_name
      )

      eventually(
        fn ->
          trace = if File.exists?(trace_file), do: File.read!(trace_file), else: ""
          assert trace =~ "\"method\":\"initialize\""
        end,
        80
      )

      refute_received {:memory_tracker_state_update, "issue-linear-agent-status-start", _state}
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      File.rm_rf(test_root)
    end
  end

  test "linear agent status change dispatch predicate only allows action states" do
    allowed = ["In Progress", "Rework", "Merging", " in progress "]
    ignored = ["Backlog", "Todo", "Blocked", "Human Review", "Done", "Canceled", "Cancelled", ""]

    for state_name <- allowed do
      assert Orchestrator.linear_agent_action_dispatchable_for_test("issueStatusChanged", %Issue{
               id: "issue-allowed-#{state_name}",
               identifier: "MT-A",
               title: "Allowed",
               state: state_name
             })
    end

    for state_name <- ignored do
      refute Orchestrator.linear_agent_action_dispatchable_for_test("issueStatusChanged", %Issue{
               id: "issue-ignored-#{state_name}",
               identifier: "MT-I",
               title: "Ignored",
               state: state_name
             })
    end

    assert Orchestrator.linear_agent_action_dispatchable_for_test("prompted", %Issue{
             id: "issue-prompted",
             identifier: "MT-P",
             title: "Prompted",
             state: "Human Review"
           })
  end

  test "linear agent issue status event ignores passive destination states" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-status-ignore-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"id":1'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-status-ignore"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-status-ignore"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        linear_agent_enabled: true,
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        prompt: "Base issue prompt for {{ issue.identifier }}"
      )

      ignored_states = ["Backlog", "Todo", "Blocked", "Human Review", "Done", "Canceled"]

      issues =
        Enum.with_index(ignored_states, fn state_name, index ->
          %Issue{
            id: "issue-linear-agent-status-ignore-#{index}",
            identifier: "MT-26#{index}",
            title: "#{state_name} ignored issue",
            description: "This should not start from issueStatusChanged",
            state: state_name,
            url: "https://example.org/issues/MT-26#{index}",
            labels: []
          }
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

      orchestrator_name = Module.concat(__MODULE__, :LinearAgentStatusIgnoreOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        System.delete_env("SYMP_TEST_CODEx_TRACE")
        File.rm_rf(test_root)
      end)

      Enum.each(issues, fn issue ->
        Orchestrator.handle_agent_session_event(
          %{
            action: "issueStatusChanged",
            agent_session_id: "agent-session-#{issue.id}",
            prompt_body: nil,
            prompt_context: "<issue identifier=\"#{issue.identifier}\"><title>#{issue.title}</title></issue>",
            issue: issue
          },
          orchestrator_name
        )
      end)

      Process.sleep(200)

      refute File.exists?(trace_file)
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "linear agent prompted event dispatches next turn after previous turn completed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-completed-turn-prompt-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"id":1'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-after-complete"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-after-complete"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      issue = %Issue{
        id: "issue-linear-agent-completed-turn",
        identifier: "MT-259",
        title: "Completed turn prompt",
        description: "Prompt after turn completion should start another turn",
        state: "Human Review",
        url: "https://example.org/issues/MT-259",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        linear_agent_enabled: true,
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        prompt: "Base issue prompt for {{ issue.identifier }}"
      )

      orchestrator_name = Module.concat(__MODULE__, :LinearAgentCompletedTurnOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        File.rm_rf(test_root)
      end)

      initial_state = :sys.get_state(pid, 15_000)
      worker_ref = make_ref()

      running_entry = %{
        pid: self(),
        ref: worker_ref,
        identifier: issue.identifier,
        issue: issue,
        session_id: "thread-existing-turn-completed",
        thread_id: "thread-existing",
        active_turn_id: nil,
        turn_count: 1,
        last_codex_message: "turn_completed",
        last_codex_timestamp: DateTime.utc_now(),
        last_codex_event: :turn_completed,
        started_at: DateTime.utc_now(),
        mode: :linear_agent,
        agent_session_id: "agent-session-259"
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue.id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
      end)

      Orchestrator.handle_agent_session_event(
        %{
          action: "prompted",
          agent_session_id: "agent-session-259",
          prompt_body: "Please continue after the completed turn.",
          prompt_context: nil,
          issue: issue
        },
        orchestrator_name
      )

      refute_receive {:symphony_steer, _steering_prompt}, 100

      eventually(fn ->
        trace = if File.exists?(trace_file), do: File.read!(trace_file), else: ""
        assert trace =~ "\"method\":\"turn/start\""
        assert trace =~ "Please continue after the completed turn."
      end)
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "linear agent webhook normalizes issue comment notifications" do
    {:ok, event} =
      SymphonyElixir.Linear.Agent.normalize_webhook(%{
        "action" => "issueNewComment",
        "appUserId" => "app-user-1",
        "notification" => %{
          "createdAt" => "2026-04-30T12:00:00Z",
          "updatedAt" => "2026-04-30T12:00:01Z",
          "actor" => %{"name" => "Konark M"},
          "issue" => %{
            "id" => "issue-agent-notification",
            "identifier" => "MT-254",
            "title" => "Notification issue",
            "state" => %{"name" => "Human Review"}
          },
          "comment" => %{
            "id" => "comment-agent-notification",
            "body" => "symphony status",
            "userId" => "human-user-1",
            "createdAt" => "2026-04-30T12:00:00Z",
            "updatedAt" => "2026-04-30T12:00:01Z"
          }
        }
      })

    assert event.action == "issueNewComment"
    assert %Issue{id: "issue-agent-notification", identifier: "MT-254", state: "Human Review"} = event.issue

    assert %Comment{
             id: "comment-agent-notification",
             body: "symphony status",
             author_id: "human-user-1",
             author_name: "Konark M",
             author_is_bot: false,
             parent_id: nil
           } = event.comment
  end

  test "linear agent top-level bridge command replies without dispatching a worker" do
    state_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-command-state-#{System.unique_integer([:positive])}.json"
      )

    issue = %Issue{
      id: "issue-linear-agent-command",
      identifier: "MT-255",
      title: "Command issue",
      description: "Handle explicit command",
      state: "Human Review",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      linear_agent_enabled: true,
      linear_agent_state_path: state_path
    )

    orchestrator_name = Module.concat(__MODULE__, :LinearAgentBridgeCommandOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(state_path)
    end)

    Orchestrator.handle_agent_session_event(
      %{
        action: "issueNewComment",
        agent_session_id: nil,
        prompt_body: nil,
        prompt_context: nil,
        issue: %{issue | state: nil},
        comment: %Comment{
          id: "linear-agent-command-status",
          body: "symphony status",
          author_name: "Konark M",
          author_is_bot: false
        }
      },
      orchestrator_name
    )

    assert_receive {:memory_tracker_comment_reaction, "linear-agent-command-status", "eyes"}
    assert_receive {:memory_tracker_comment_reply, "issue-linear-agent-command", "linear-agent-command-status", reply}
    assert reply =~ "Status: Human Review"
    assert reply =~ "Paused: no"

    updated_state = :sys.get_state(pid, 15_000)
    issue_state = SymphonyElixir.StateStore.get_issue(issue.id)
    assert issue_state["last_command"] == "status"
    assert issue_state["last_command_comment_id"] == "linear-agent-command-status"

    refute Map.has_key?(updated_state.running, issue.id)
    assert %{command: "status", issue_identifier: "MT-255"} = updated_state.last_bridge_command
  end

  test "linear agent unknown bridge command is idempotent by comment id" do
    state_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-unknown-command-state-#{System.unique_integer([:positive])}.json"
      )

    issue = %Issue{
      id: "issue-linear-agent-unknown-command",
      identifier: "MT-257",
      title: "Unknown command issue",
      description: "Handle duplicate explicit command",
      state: "Human Review",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      linear_agent_enabled: true,
      linear_agent_state_path: state_path
    )

    orchestrator_name = Module.concat(__MODULE__, :LinearAgentUnknownCommandOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(state_path)
    end)

    event = %{
      action: "issueNewComment",
      agent_session_id: nil,
      prompt_body: nil,
      prompt_context: nil,
      issue: issue,
      comment: %Comment{
        id: "linear-agent-command-unknown",
        body: "symphony dance",
        author_name: "Konark M",
        author_is_bot: false
      }
    }

    Orchestrator.handle_agent_session_event(event, orchestrator_name)

    assert_receive {:memory_tracker_comment_reaction, "linear-agent-command-unknown", "eyes"}
    assert_receive {:memory_tracker_comment_reply, "issue-linear-agent-unknown-command", "linear-agent-command-unknown", reply}
    assert reply =~ "Unknown Symphony command `dance`"

    _updated_state = :sys.get_state(pid, 15_000)

    Orchestrator.handle_agent_session_event(event, orchestrator_name)

    refute_receive {:memory_tracker_comment_reaction, "linear-agent-command-unknown", "eyes"}, 100
    refute_receive {:memory_tracker_comment_reply, _, _, _}, 100
  end

  test "linear agent top-level issue comments are passive unless they are bridge commands" do
    state_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-comment-state-#{System.unique_integer([:positive])}.json"
      )

    issue = %Issue{
      id: "issue-linear-agent-comment",
      identifier: "MT-256",
      title: "Comment issue",
      description: "Route top-level comments",
      state: "Human Review",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      linear_agent_enabled: true,
      linear_agent_state_path: state_path
    )

    orchestrator_name = Module.concat(__MODULE__, :LinearAgentIssueCommentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(state_path)
    end)

    initial_state = :sys.get_state(pid, 15_000)
    worker_ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: worker_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      thread_id: "thread-existing",
      active_turn_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now(),
      mode: :linear_agent,
      agent_session_id: "agent-session-256"
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
    end)

    Orchestrator.handle_agent_session_event(
      %{
        action: "issueNewComment",
        agent_session_id: nil,
        prompt_body: nil,
        prompt_context: nil,
        issue: issue,
        comment: %Comment{
          id: "linear-agent-human-comment",
          body: "Please tighten the spacing.",
          author_name: "Konark M",
          author_is_bot: false
        }
      },
      orchestrator_name
    )

    refute_receive {:memory_tracker_comment_reaction, "linear-agent-human-comment", "eyes"}, 100
    refute_receive {:symphony_steer, _steering_prompt}, 100

    Orchestrator.handle_agent_session_event(
      %{
        action: "issueNewComment",
        agent_session_id: nil,
        prompt_body: nil,
        prompt_context: nil,
        issue: issue,
        comment: %Comment{
          id: "linear-agent-reply-command",
          body: "symphony status",
          parent_id: "parent-comment",
          author_name: "Konark M",
          author_is_bot: false
        }
      },
      orchestrator_name
    )

    Orchestrator.handle_agent_session_event(
      %{
        action: "issueNewComment",
        agent_session_id: nil,
        prompt_body: nil,
        prompt_context: nil,
        issue: issue,
        comment: %Comment{
          id: "linear-agent-bot-command",
          body: "symphony status",
          author_name: "Symphony",
          author_is_bot: true
        }
      },
      orchestrator_name
    )

    refute_receive {:memory_tracker_comment_reaction, "linear-agent-reply-command", "eyes"}, 100
    refute_receive {:memory_tracker_comment_reaction, "linear-agent-bot-command", "eyes"}, 100
    refute_receive {:memory_tracker_comment_reply, _, _, _}, 100
  end

  test "linear agent comment polling marks non-command comments as passive context" do
    state_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-polled-comment-state-#{System.unique_integer([:positive])}.json"
      )

    {:ok, old_time, _offset} = DateTime.from_iso8601("2026-04-30T12:00:00Z")
    {:ok, comment_time, _offset} = DateTime.from_iso8601("2026-04-30T12:01:00Z")

    issue = %Issue{
      id: "issue-linear-agent-polled-comment",
      identifier: "MT-258",
      title: "Polled comment issue",
      description: "Human Review comments should stay passive in Linear Agent mode",
      state: "Human Review",
      labels: []
    }

    old_comment = %Comment{
      id: "linear-agent-old-comment",
      body: "9 * 9 = 81.",
      created_at: old_time,
      updated_at: old_time,
      author_name: "Symphony",
      author_is_bot: true
    }

    human_comment = %Comment{
      id: "linear-agent-polled-human-comment",
      body: "Saw this. Please confirm briefly.",
      created_at: comment_time,
      updated_at: comment_time,
      author_name: "Konark M",
      author_is_bot: false
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue.id => [old_comment, human_comment]
    })

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      linear_agent_enabled: true,
      linear_agent_state_path: state_path
    )

    on_exit(fn -> File.rm_rf(state_path) end)

    :ok =
      SymphonyElixir.StateStore.put_issue(issue.id, %{
        agent_session_id: "agent-session-258",
        thread_id: "thread-258",
        last_seen_comment_id: old_comment.id,
        last_seen_comment_updated_at: DateTime.to_iso8601(old_time)
      })

    state = %Orchestrator.State{
      max_concurrent_agents: 0,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    _updated_state = Orchestrator.poll_comment_steering_for_test(state)

    refute_receive {:memory_tracker_comment_reaction, "linear-agent-polled-human-comment", "eyes"}, 100
    refute_receive {:memory_tracker_comment_update, _, _}, 100
    refute_receive {:symphony_steer, _}, 100

    issue_state = SymphonyElixir.StateStore.get_issue(issue.id)
    assert issue_state["agent_session_id"] == "agent-session-258"
    assert issue_state["thread_id"] == "thread-258"
    assert issue_state["last_seen_comment_id"] == "linear-agent-polled-human-comment"
  end

  test "linear agent session polling starts delegated non-review issues regardless of workflow state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      linear_agent_enabled: true,
      tracker_terminal_states: ["Done", "Canceled"]
    )

    backlog_issue = %Issue{
      id: "issue-agent-backlog",
      identifier: "KM-POLL",
      title: "Delegated from Backlog",
      state: "Backlog"
    }

    todo_issue = %{backlog_issue | id: "issue-agent-todo", state: "Todo"}
    review_issue = %{backlog_issue | id: "issue-agent-review", state: "Human Review"}
    done_issue = %{backlog_issue | id: "issue-agent-done", state: "Done"}

    assert Orchestrator.linear_agent_session_poll_candidate_for_test(backlog_issue, "stale")
    assert Orchestrator.linear_agent_session_poll_candidate_for_test(todo_issue, "active")
    refute Orchestrator.linear_agent_session_poll_candidate_for_test(review_issue, "stale")
    refute Orchestrator.linear_agent_session_poll_candidate_for_test(done_issue, "stale")
    refute Orchestrator.linear_agent_session_poll_candidate_for_test(backlog_issue, "complete")
  end

  test "linear agent running room stays alive in delegated backlog state" do
    issue = %Issue{
      id: "issue-agent-backlog-running",
      identifier: "KM-RUN",
      title: "Delegated from Backlog",
      state: "Backlog",
      assigned_to_worker: true
    }

    worker = spawn(fn -> Process.sleep(:infinity) end)
    worker_ref = Process.monitor(worker)

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: worker,
          ref: worker_ref,
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          mode: :linear_agent
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated_state =
      Orchestrator.reconcile_issue_state_for_test(
        issue,
        state,
        ["Todo", "In Progress"],
        ["Done", "Canceled"]
      )

    assert Map.has_key?(updated_state.running, issue.id)
    assert MapSet.member?(updated_state.claimed, issue.id)
    assert Process.alive?(worker)

    Process.demonitor(worker_ref, [:flush])
    Process.exit(worker, :kill)
  end

  test "linear agent running room stops when issue is no longer routed to Symphony" do
    issue = %Issue{
      id: "issue-agent-unassigned-running",
      identifier: "KM-UNROUTED",
      title: "No longer delegated",
      state: "Backlog",
      assigned_to_worker: false
    }

    worker = spawn(fn -> Process.sleep(:infinity) end)
    worker_ref = Process.monitor(worker)

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: worker,
          ref: worker_ref,
          identifier: issue.identifier,
          issue: %{issue | assigned_to_worker: true},
          started_at: DateTime.utc_now(),
          mode: :linear_agent
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated_state =
      Orchestrator.reconcile_issue_state_for_test(
        issue,
        state,
        ["Todo", "In Progress"],
        ["Done", "Canceled"]
      )

    refute Map.has_key?(updated_state.running, issue.id)
    refute MapSet.member?(updated_state.claimed, issue.id)

    eventually(fn ->
      refute Process.alive?(worker)
    end)

    Process.demonitor(worker_ref, [:flush])
  end

  test "linear agent created acknowledgement is deduped per AgentSession" do
    assert Orchestrator.linear_agent_created_ack_needed_for_test(%{}, "session-1")

    refute Orchestrator.linear_agent_created_ack_needed_for_test(
             %{"last_acknowledged_agent_session_id" => "session-1"},
             "session-1"
           )

    assert Orchestrator.linear_agent_created_ack_needed_for_test(
             %{"last_acknowledged_agent_session_id" => "session-1"},
             "session-2"
           )
  end

  test "linear agent retries once with a fresh thread when resumed thread is interrupted" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-fresh-thread-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      interrupted_marker = Path.join(test_root, "interrupted-once")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      interrupted_marker="#{interrupted_marker}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"id":1'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"old-thread"}}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"new-thread"}}}'
            ;;
          *'"method":"turn/start"'*)
            if [ ! -f "$interrupted_marker" ]; then
              touch "$interrupted_marker"
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"cancelled-turn"}}}'
              printf '%s\\n' '{"method":"turn/cancelled","params":{"reason":"interrupted"}}'
              exit 0
            else
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"new-turn"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
            fi
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        prompt: "Base issue prompt for {{ issue.identifier }}"
      )

      issue = %Issue{
        id: "issue-linear-agent-fallback",
        identifier: "MT-253",
        title: "Recover interrupted thread",
        description: "Retry on fresh thread",
        state: "Human Review",
        url: "https://example.org/issues/MT-253",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 linear_agent: true,
                 existing_thread_id: "old-thread",
                 agent_session_id: "agent-session-253"
               )

      trace = File.read!(trace_file)
      assert trace =~ "\"method\":\"thread/resume\""
      assert trace =~ "\"threadId\":\"old-thread\""
      assert trace =~ "\"method\":\"thread/start\""
      assert trace =~ "Base issue prompt for MT-253"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "linear agent retries once with a fresh thread when a new thread is interrupted" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-fresh-thread-interrupted-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      interrupted_marker = Path.join(test_root, "interrupted-once")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      interrupted_marker="#{interrupted_marker}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"id":1'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            if [ ! -f "$interrupted_marker" ]; then
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"interrupted-thread"}}}'
            else
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"recovered-thread"}}}'
            fi
            ;;
          *'"method":"turn/start"'*)
            if [ ! -f "$interrupted_marker" ]; then
              touch "$interrupted_marker"
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"cancelled-turn"}}}'
              printf '%s\\n' '{"method":"turn/cancelled","params":{"reason":"interrupted"}}'
              exit 0
            else
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"recovered-turn"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
            fi
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        prompt: "Base issue prompt for {{ issue.identifier }}"
      )

      issue = %Issue{
        id: "issue-linear-agent-fresh-interrupted",
        identifier: "MT-254",
        title: "Recover interrupted fresh thread",
        description: "Retry on fresh thread",
        state: "In Progress",
        url: "https://example.org/issues/MT-254",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 linear_agent: true,
                 agent_session_id: "agent-session-254"
               )

      trace = File.read!(trace_file)
      assert trace |> String.split(~S("method":"thread/start")) |> length() == 3
      assert trace =~ "recovered-thread"
      assert trace =~ "Base issue prompt for MT-254"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "linear agent does not retry a fresh thread for resumed turn failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-agent-no-fresh-thread-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"id":1'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"old-thread"}}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"new-thread"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"failed-turn"}}}'
            printf '%s\\n' '{"method":"turn/failed","params":{"reason":"tool_error"}}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        prompt: "Base issue prompt for {{ issue.identifier }}"
      )

      issue = %Issue{
        id: "issue-linear-agent-no-fallback",
        identifier: "MT-258",
        title: "Do not retry failed turn",
        description: "No fresh thread on semantic failure",
        state: "Human Review",
        url: "https://example.org/issues/MT-258",
        labels: []
      }

      assert_raise RuntimeError, ~r/:turn_failed/, fn ->
        AgentRunner.run(
          issue,
          nil,
          linear_agent: true,
          existing_thread_id: "old-thread",
          agent_session_id: "agent-session-258"
        )
      end

      trace = File.read!(trace_file)
      assert trace =~ "\"method\":\"thread/resume\""
      assert trace =~ "\"threadId\":\"old-thread\""
      refute trace =~ "\"method\":\"thread/start\""
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            send(self(), {:symphony_queue_steering, "Konark: please include the Linear comment context"})
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
      assert Enum.at(turn_texts, 1) =~ "New Linear comments since the last turn:"
      assert Enum.at(turn_texts, 1) =~ "Konark: please include the Linear comment context"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner parks after issue reaches Human Review" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-human-review-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        tracker_active_states: ["Todo", "In Progress", "Human Review", "Rework", "Merging"],
        max_turns: 3
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-human-review",
             identifier: "MT-249",
             title: "Park at review",
             description: "Wait for humans",
             state: "Human Review"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-human-review",
        identifier: "MT-249",
        title: "Park at review",
        description: "Wait for humans",
        state: "In Progress",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner includes Human Review comment-run instructions and thread reply context" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-comment-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-comment"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-comment-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        tracker_active_states: ["Todo", "In Progress", "Human Review", "Rework", "Merging"],
        max_turns: 3
      )

      {:ok, comment_time, _offset} = DateTime.from_iso8601("2026-04-28T01:01:00Z")

      comment = %Comment{
        id: "comment-review-1",
        body: "Can you explain the validation?",
        created_at: comment_time,
        updated_at: comment_time,
        author_name: "Konark"
      }

      issue = %Issue{
        id: "issue-review-comment",
        identifier: "MT-250",
        title: "Reply from review",
        description: "Talk back from Human Review",
        state: "Human Review",
        url: "https://example.org/issues/MT-250",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 review_comment_mode: true,
                 review_comments: [comment],
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Human Review"}]} end
               )

      turn_text =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "turn/start"))
        |> get_in(["params", "input"])
        |> Enum.map_join("\n", &Map.get(&1, "text", ""))

      assert turn_text =~ "Human Review comment run:"
      assert turn_text =~ "comment_id=comment-review-1"
      assert turn_text =~ "parentId: \"<comment_id>\""
      assert turn_text =~ "leave the issue in Human Review"
      assert turn_text =~ "move the issue to Rework"
      refute turn_text =~ "Natural approval comments trigger merging"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 1 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(100)
      eventually(fun, attempts - 1)
  end

  defp eventually(fun, 1), do: fun.()
end
