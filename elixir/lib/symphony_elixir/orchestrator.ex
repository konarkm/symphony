defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StateStore, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.{Agent, BridgeCommand, Comment, CommentSteering, Issue}

  @continuation_retry_delay_ms 1_000
  @comment_poll_interval_ms 5_000
  @failure_retry_base_ms 10_000
  @human_review_state "Human Review"
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :comment_timer_ref,
      :comment_poll_token,
      :last_linear_comment_poll_at,
      :last_successful_comment_poll_at,
      :last_linear_comment_poll_error,
      :last_bridge_command,
      watched_human_review_count: 0,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec handle_agent_session_event(map(), GenServer.server()) :: :ok
  def handle_agent_session_event(event, server \\ __MODULE__) when is_map(event) do
    GenServer.cast(server, {:linear_agent_session_event, event})
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    maybe_run_terminal_workspace_cleanup(config)

    state =
      state
      |> schedule_tick(0)
      |> schedule_comment_poll(@comment_poll_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_cast({:linear_agent_session_event, event}, state) when is_map(event) do
    state = refresh_runtime_config(state)
    {:noreply, handle_linear_agent_session_event(state, event)}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:poll_comments, comment_poll_token}, %{comment_poll_token: comment_poll_token} = state)
      when is_reference(comment_poll_token) do
    state =
      state
      |> poll_comment_steering()
      |> schedule_comment_poll(@comment_poll_interval_ms)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:poll_comments, _comment_poll_token}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              complete_normal_agent_run(state, issue_id, running_entry, session_id)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                issue: Map.get(running_entry, :issue),
                error: "agent exited: #{inspect(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        maybe_store_linear_agent_thread(issue_id, updated_running_entry)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    if Config.settings!().linear_agent.enabled do
      state
      |> reconcile_running_issues()
      |> maybe_dispatch_linear_agent_sessions()
    else
      maybe_dispatch_polling(state)
    end
  end

  defp maybe_dispatch_linear_agent_sessions(%State{} = state) do
    with :ok <- Config.validate!(),
         true <- available_slots(state) > 0,
         {:ok, sessions} <- Agent.recent_sessions() do
      sessions
      |> Enum.reduce(state, &maybe_dispatch_linear_agent_session/2)
    else
      {:error, reason} ->
        Logger.error("Failed to fetch Linear AgentSessions: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp maybe_dispatch_linear_agent_session(%{id: session_id, issue: %Issue{} = issue, status: status}, %State{} = state)
       when is_binary(session_id) do
    cond do
      not linear_agent_session_poll_status?(status) ->
        state

      not linear_agent_session_issue_dispatchable?(issue) ->
        state

      linear_agent_issue_paused?(issue.id) ->
        state

      Map.has_key?(state.running, issue.id) ->
        state

      MapSet.member?(state.claimed, issue.id) ->
        state

      available_slots(state) <= 0 ->
        state

      true ->
        Logger.info("Starting delegated Linear AgentSession from poll fallback: session_id=#{session_id} #{issue_context(issue)} state=#{issue.state || "unknown"}")

        persist_linear_agent_session_id(issue.id, session_id)

        handle_linear_agent_session_event(state, %{
          action: "created",
          agent_session_id: session_id,
          issue: issue,
          prompt_body: nil,
          prompt_context: nil
        })
    end
  end

  defp maybe_dispatch_linear_agent_session(_session, %State{} = state), do: state

  defp linear_agent_session_poll_status?(status) when is_binary(status) do
    status in ["active", "stale"]
  end

  defp linear_agent_session_poll_status?(_status), do: false

  defp linear_agent_session_issue_dispatchable?(%Issue{} = issue) do
    state_name = issue.state

    is_binary(issue.id) and
      is_binary(issue.identifier) and
      is_binary(issue.title) and
      is_binary(state_name) and
      not waiting_for_human_review_state?(state_name) and
      not terminal_issue_state?(state_name, terminal_state_set())
  end

  defp maybe_dispatch_polling(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec linear_agent_session_poll_candidate_for_test(Issue.t(), String.t() | nil) :: boolean()
  def linear_agent_session_poll_candidate_for_test(%Issue{} = issue, status) do
    linear_agent_session_poll_status?(status) and linear_agent_session_issue_dispatchable?(issue)
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec poll_comment_steering_for_test(term()) :: term()
  def poll_comment_steering_for_test(%State{} = state), do: poll_comment_steering(state)

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      waiting_for_human_review_state?(issue.state) and human_review_worker_continues?(state, issue.id) ->
        refresh_running_issue_state(state, issue)

      waiting_for_human_review_state?(issue.state) ->
        Logger.info("Issue moved to Human Review: #{issue_context(issue)} state=#{issue.state}; parking active agent")

        terminate_running_issue(state, issue.id, false)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)
        cleanup_workspace = cleanup_workspace and Map.get(running_entry, :mode) != :linear_agent

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        issue: Map.get(running_entry, :issue),
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      dispatchable_issue_state?(issue.state) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp dispatchable_issue_state?(state_name) when is_binary(state_name) do
    not waiting_for_human_review_state?(state_name)
  end

  defp dispatchable_issue_state?(_state_name), do: false

  defp waiting_for_human_review_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "human review"
  end

  defp waiting_for_human_review_state?(_state_name), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil, runner_opts \\ []) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        if issue_paused_by_marker?(refreshed_issue) do
          Logger.info("Skipping dispatch for paused issue: #{issue_context(refreshed_issue)}")
          state
        else
          do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, runner_opts)
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp handle_linear_agent_session_event(
         %State{} = state,
         %{action: "issueNewComment", issue: %Issue{} = issue, comment: %Comment{} = comment} = event
       ) do
    issue = refresh_linear_agent_issue(issue)
    event = Map.put(event, :issue, issue)

    cond do
      not top_level_human_comment?(comment) ->
        state

      BridgeCommand.command?(comment) ->
        handle_linear_agent_bridge_command(state, issue, comment)

      linear_agent_issue_paused?(issue.id) ->
        acknowledge_comment(comment)
        Logger.info("Issue is paused; acknowledged Linear Agent issue comment without worker routing for #{issue_context(issue)}")
        state

      true ->
        handle_linear_agent_issue_comment(state, issue, comment, event)
    end
  end

  defp handle_linear_agent_session_event(%State{} = state, %{issue: %Issue{} = issue} = event) do
    issue = refresh_linear_agent_issue(issue)
    event = Map.put(event, :issue, issue)

    case Map.get(event, :action) do
      action when action in ["created", "prompted", "issueAssignedToYou", "issueStatusChanged"] ->
        agent_session_id = agent_session_id_for_event(event, issue)
        prompt = linear_agent_prompt(event)
        Logger.info("Linear AgentSession action=#{action} session_id=#{agent_session_id || "unknown"} #{issue_context(issue)} state=#{issue.state || "unknown"}")

        case Map.get(state.running, issue.id) do
          %{pid: pid} = running_entry when is_pid(pid) ->
            handle_existing_linear_agent_process(state, issue, event, action, agent_session_id, running_entry, prompt)

          _ ->
            dispatch_linear_agent_session_event(state, issue, event, action, agent_session_id)
        end

      _ ->
        Logger.debug("Ignoring Linear AgentSession action=#{inspect(Map.get(event, :action))}")
        state
    end
  end

  defp handle_linear_agent_session_event(state, event) do
    Logger.warning("Ignoring Linear AgentSession event without issue: #{inspect(Map.take(event, [:action, :agent_session_id]))}")
    state
  end

  defp handle_linear_agent_bridge_command(%State{} = state, %Issue{} = issue, %Comment{} = comment) do
    case BridgeCommand.parse(comment) do
      {:ok, command} ->
        apply_linear_agent_bridge_command(state, issue, comment, command)

      {:error, :unknown_command, unknown} ->
        apply_unknown_linear_agent_bridge_command(state, issue, comment, unknown)

      :not_command ->
        state
    end
  end

  defp apply_unknown_linear_agent_bridge_command(%State{} = state, %Issue{} = issue, %Comment{} = comment, unknown) do
    issue_state = StateStore.get_issue(issue.id)

    if Map.get(issue_state, "last_command_comment_id") == comment.id do
      state
    else
      case StateStore.put_issue(issue.id, %{
             last_seen_comment_id: comment.id,
             last_seen_comment_updated_at: comment_timestamp_iso8601(comment),
             paused: Map.get(issue_state, "paused") == true,
             last_command: "unknown",
             last_command_comment_id: comment.id,
             last_command_at: DateTime.to_iso8601(DateTime.utc_now())
           }) do
        :ok ->
          acknowledge_comment(comment)
          reply_to_bridge_command(issue, comment, "Unknown Symphony command `#{unknown}`. #{BridgeCommand.help_text()}")

          %{
            state
            | last_bridge_command: %{
                issue_id: issue.id,
                issue_identifier: issue.identifier,
                comment_id: comment.id,
                command: "unknown",
                at: DateTime.utc_now()
              }
          }

        {:error, reason} ->
          Logger.warning("Unable to persist Linear Agent bridge command marker for #{issue_context(issue)} comment_id=#{comment.id}: #{inspect(reason)}")
          state
      end
    end
  end

  defp apply_linear_agent_bridge_command(%State{} = state, %Issue{} = issue, %Comment{} = comment, command) do
    issue_state = StateStore.get_issue(issue.id)

    if Map.get(issue_state, "last_command_comment_id") == comment.id do
      state
    else
      marker = %{paused: Map.get(issue_state, "paused") == true}
      paused? = bridge_command_paused_after(command, marker)

      case StateStore.put_issue(issue.id, %{
             last_seen_comment_id: comment.id,
             last_seen_comment_updated_at: comment_timestamp_iso8601(comment),
             paused: paused?,
             last_command: command.action_text,
             last_command_comment_id: comment.id,
             last_command_at: DateTime.to_iso8601(DateTime.utc_now())
           }) do
        :ok ->
          acknowledge_comment(comment)
          {state, reply, _paused?} = apply_bridge_command(state, issue, command, marker)
          reply_to_bridge_command(issue, comment, reply)
          %{state | last_bridge_command: bridge_command_snapshot(issue, comment, command)}

        {:error, reason} ->
          Logger.warning("Unable to persist Linear Agent bridge command marker for #{issue_context(issue)} comment_id=#{comment.id}: #{inspect(reason)}")
          state
      end
    end
  end

  defp bridge_command_paused_after(%{action: :pause}, _marker), do: true
  defp bridge_command_paused_after(%{action: :cancel}, _marker), do: true
  defp bridge_command_paused_after(%{action: :resume}, _marker), do: false
  defp bridge_command_paused_after(_command, marker), do: CommentSteering.paused?(marker)

  defp handle_linear_agent_issue_comment(%State{} = state, %Issue{} = issue, %Comment{} = comment, event) do
    issue_state = StateStore.get_issue(issue.id)

    agent_session_id =
      Map.get(event, :agent_session_id) ||
        Map.get(issue_state, "agent_session_id") ||
        get_in(state.running, [issue.id, :agent_session_id])

    if is_binary(agent_session_id) and agent_session_id != "" do
      acknowledge_comment(comment)

      handle_linear_agent_session_event(state, %{
        event
        | action: "prompted",
          agent_session_id: agent_session_id,
          prompt_body: linear_agent_comment_prompt(comment)
      })
    else
      Logger.info("Ignoring non-command Linear issue comment without known AgentSession for #{issue_context(issue)} comment_id=#{comment.id}")
      state
    end
  end

  defp linear_agent_comment_prompt(%Comment{} = comment) do
    author = comment.author_name || "A human"
    body = comment.body || ""

    """
    New top-level Linear issue comment from #{author}:

    #{body}
    """
  end

  defp linear_agent_comment_batch_prompt(comments) when is_list(comments) do
    """
    New top-level Linear issue comment context arrived:

    #{CommentSteering.format_review_context(comments)}
    """
  end

  defp latest_agent_session_id_for_issue(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Agent.latest_session_id_for_issue(issue_id) do
      {:ok, session_id} -> session_id
      {:error, _reason} -> nil
    end
  end

  defp latest_agent_session_id_for_issue(_issue), do: nil

  defp linear_agent_comment_marker_state(issue_id) when is_binary(issue_id) do
    issue_state = StateStore.get_issue(issue_id)

    marker = %{
      last_seen_comment_id: Map.get(issue_state, "last_seen_comment_id"),
      last_seen_comment_updated_at: Map.get(issue_state, "last_seen_comment_updated_at"),
      paused: Map.get(issue_state, "paused") == true
    }

    with id when is_binary(id) and id != "" <- marker.last_seen_comment_id,
         updated_at when is_binary(updated_at) <- marker.last_seen_comment_updated_at,
         {:ok, %DateTime{}, _offset} <- DateTime.from_iso8601(updated_at) do
      {:ok, marker}
    else
      _ -> :missing
    end
  end

  defp persist_latest_linear_agent_comment_marker(issue_id, comments) when is_binary(issue_id) and is_list(comments) do
    comments
    |> CommentSteering.latest_marker()
    |> persist_linear_agent_comment_marker(issue_id)
  end

  defp persist_linear_agent_comment_marker(marker, issue_id) when is_map(marker) and is_binary(issue_id) do
    StateStore.put_issue(issue_id, %{
      last_seen_comment_id: marker[:last_seen_comment_id],
      last_seen_comment_updated_at: marker[:last_seen_comment_updated_at],
      paused: CommentSteering.paused?(marker)
    })
  end

  defp comment_timestamp_iso8601(%Comment{created_at: %DateTime{} = created_at}), do: DateTime.to_iso8601(created_at)
  defp comment_timestamp_iso8601(%Comment{updated_at: %DateTime{} = updated_at}), do: DateTime.to_iso8601(updated_at)
  defp comment_timestamp_iso8601(_comment), do: DateTime.to_iso8601(DateTime.utc_now())

  defp linear_agent_issue_paused?(issue_id) when is_binary(issue_id) do
    StateStore.get_issue(issue_id)
    |> Map.get("paused")
    |> Kernel.==(true)
  end

  defp linear_agent_issue_paused?(_issue_id), do: false

  defp top_level_human_comment?(%Comment{author_is_bot: true}), do: false
  defp top_level_human_comment?(%Comment{parent_id: parent_id}) when is_binary(parent_id) and parent_id != "", do: false
  defp top_level_human_comment?(%Comment{}), do: true

  defp handle_existing_linear_agent_process(
         state,
         issue,
         event,
         action,
         agent_session_id,
         %{pid: pid} = running_entry,
         prompt
       ) do
    if Process.alive?(pid) and linear_agent_turn_steerable?(running_entry) do
      maybe_steer_running_linear_agent(pid, event, prompt)
      state
    else
      dispatch_linear_agent_session_event(state, issue, event, action, agent_session_id)
    end
  end

  defp linear_agent_turn_steerable?(%{active_turn_id: active_turn_id})
       when is_binary(active_turn_id) and active_turn_id != "",
       do: true

  defp linear_agent_turn_steerable?(%{last_codex_event: event})
       when event in [:turn_completed, :turn_failed, :turn_cancelled, :turn_ended_with_error],
       do: false

  defp linear_agent_turn_steerable?(_running_entry), do: true

  defp dispatch_linear_agent_session_event(state, issue, event, action, agent_session_id) do
    acknowledge_agent_session(agent_session_id, action, issue.id)

    runner_opts =
      [
        mode: :linear_agent,
        linear_agent: true,
        agent_session_id: agent_session_id,
        prompt_context: Map.get(event, :prompt_context),
        prompt_body: Map.get(event, :prompt_body),
        existing_thread_id: StateStore.get_issue(issue.id) |> Map.get("thread_id")
      ]

    state
    |> release_issue_claim(issue.id)
    |> do_dispatch_issue(%{issue | assigned_to_worker: true}, nil, nil, runner_opts)
  end

  defp maybe_steer_running_linear_agent(pid, %{action: "prompted"}, prompt)
       when is_pid(pid) and is_binary(prompt) and prompt != "" do
    send(pid, {:symphony_steer, prompt})
    :ok
  end

  defp maybe_steer_running_linear_agent(_pid, _event, _prompt), do: :ok

  defp agent_session_id_for_event(event, %Issue{id: issue_id}) do
    case Map.get(event, :agent_session_id) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        case Agent.latest_session_id_for_issue(issue_id) do
          {:ok, session_id} ->
            session_id

          {:error, reason} ->
            Logger.warning("Unable to find active Linear AgentSession for issue_id=#{issue_id}: #{inspect(reason)}")
            nil
        end
    end
  end

  defp agent_session_id_for_event(event, _issue), do: Map.get(event, :agent_session_id)

  defp refresh_linear_agent_issue(%Issue{id: issue_id} = issue) when is_binary(issue_id) and issue_id != "" do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = refreshed | _]} ->
        refreshed

      {:ok, []} ->
        Logger.warning("Linear AgentSession issue refresh returned no issue for #{issue_context(issue)}; using webhook payload")
        issue

      {:error, reason} ->
        Logger.warning("Linear AgentSession issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}; using webhook payload")
        issue
    end
  end

  defp refresh_linear_agent_issue(%Issue{} = issue), do: issue

  defp acknowledge_agent_session(nil, _action, _issue_id), do: :ok

  defp acknowledge_agent_session(agent_session_id, "created", issue_id)
       when is_binary(agent_session_id) and is_binary(issue_id) do
    issue_state = StateStore.get_issue(issue_id)

    if linear_agent_created_ack_needed?(issue_state, agent_session_id) do
      Agent.create_activity(agent_session_id, %{
        "type" => "thought",
        "body" => "I picked this up and am reading the issue context."
      })

      StateStore.put_issue(issue_id, %{
        last_acknowledged_agent_session_id: agent_session_id,
        last_acknowledged_agent_session_at: DateTime.to_iso8601(DateTime.utc_now())
      })
    else
      :ok
    end
  end

  defp acknowledge_agent_session(agent_session_id, _action, _issue_id) when is_binary(agent_session_id) do
    Agent.create_activity(agent_session_id, %{
      "type" => "thought",
      "body" => "I saw the new prompt and am checking what needs to change."
    })
  end

  @doc false
  @spec linear_agent_created_ack_needed_for_test(map(), String.t()) :: boolean()
  def linear_agent_created_ack_needed_for_test(issue_state, agent_session_id) do
    linear_agent_created_ack_needed?(issue_state, agent_session_id)
  end

  defp linear_agent_created_ack_needed?(issue_state, agent_session_id)
       when is_map(issue_state) and is_binary(agent_session_id) do
    Map.get(issue_state, "last_acknowledged_agent_session_id") != agent_session_id
  end

  defp linear_agent_created_ack_needed?(_issue_state, _agent_session_id), do: true

  defp linear_agent_prompt(event) do
    [
      "Linear AgentSession event: #{Map.get(event, :action)}",
      session_line(Map.get(event, :agent_session_id)),
      prompt_context_block(Map.get(event, :prompt_context)),
      prompt_body_block(Map.get(event, :prompt_body))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp session_line(nil), do: nil
  defp session_line(agent_session_id), do: "Agent session id: #{agent_session_id}"

  defp prompt_context_block(nil), do: nil
  defp prompt_context_block(prompt_context), do: "Prompt context:\n#{prompt_context}"

  defp prompt_body_block(nil), do: nil
  defp prompt_body_block(prompt_body), do: "New prompt:\n#{prompt_body}"

  defp dispatch_review_comment_issue(%State{} = state, %Issue{} = issue, comments) when is_list(comments) do
    runner_opts = [
      review_comment_mode: true,
      review_comments: comments,
      steering_comments: [CommentSteering.format_steering_message(comments)]
    ]

    cond do
      not dispatch_slots_available?(issue, state) ->
        schedule_issue_retry(state, issue.id, nil, %{
          identifier: issue.identifier,
          issue: issue,
          delay_type: :review_comment,
          mode: :review_comment,
          pending_review_comments: comments,
          pending_steering_comments: runner_opts[:steering_comments],
          error: "no available orchestrator slots"
        })

      not worker_slots_available?(state) ->
        schedule_issue_retry(state, issue.id, nil, %{
          identifier: issue.identifier,
          issue: issue,
          delay_type: :review_comment,
          mode: :review_comment,
          pending_review_comments: comments,
          pending_steering_comments: runner_opts[:steering_comments],
          error: "no available worker slots"
        })

      true ->
        Logger.info("Dispatching Human Review comment run for #{issue_context(issue)} comments=#{length(comments)}")
        do_dispatch_issue(state, issue, nil, nil, runner_opts ++ [mode: :review_comment])
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, runner_opts) do
    issue = prepare_issue_for_dispatch(issue, runner_opts)
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, runner_opts)
    end
  end

  defp prepare_issue_for_dispatch(%Issue{} = issue, runner_opts) do
    if Keyword.get(runner_opts, :linear_agent) == true do
      issue
    else
      prepare_issue_for_dispatch(issue)
    end
  end

  defp prepare_issue_for_dispatch(%Issue{state: state_name} = issue)
       when is_binary(state_name) do
    move_issue_to_started_for_linear_agent(issue)
  end

  defp prepare_issue_for_dispatch(issue), do: issue

  defp move_issue_to_started_for_linear_agent(%Issue{state: state_name} = issue)
       when is_binary(state_name) do
    normalized = normalize_issue_state(state_name)

    if normalized in ["in progress", "blocked", "human review", "rework", "merging", "done", "canceled", "cancelled", "duplicate", "closed"] do
      issue
    else
      move_issue_to_in_progress(issue)
    end
  end

  defp move_issue_to_started_for_linear_agent(issue), do: move_issue_to_in_progress(issue)

  defp move_issue_to_in_progress(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    case Tracker.update_issue_state(issue_id, "In Progress") do
      :ok ->
        %{issue | state: "In Progress"}

      {:error, reason} ->
        Logger.warning("Unable to move #{issue_context(issue)} to In Progress before dispatch: #{inspect(reason)}")
        issue
    end
  end

  defp move_issue_to_in_progress(issue), do: issue

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, runner_opts) do
    mode = Keyword.get(runner_opts, :mode, :normal)

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(
             issue,
             recipient,
             runner_opts
             |> Keyword.put(:attempt, attempt)
             |> Keyword.put(:worker_host, worker_host)
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            thread_id: nil,
            active_turn_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            mode: mode,
            agent_session_id: Keyword.get(runner_opts, :agent_session_id),
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue: issue,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_normal_agent_run(%State{} = state, issue_id, %{mode: :review_comment} = running_entry, session_id) do
    pending_review_comments = Map.get(running_entry, :pending_review_comments, [])

    if pending_review_comments == [] do
      Logger.info("Human Review comment run completed for issue_id=#{issue_id} session_id=#{session_id}; releasing review claim")

      state
      |> complete_issue(issue_id)
      |> release_issue_claim(issue_id)
    else
      Logger.info("Human Review comment run completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling queued review comments=#{length(pending_review_comments)}")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue: Map.get(running_entry, :issue),
        delay_type: :review_comment,
        mode: :review_comment,
        pending_review_comments: pending_review_comments,
        pending_steering_comments: Map.get(running_entry, :pending_steering_comments, []),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp complete_normal_agent_run(%State{} = state, issue_id, %{mode: :linear_agent}, session_id) do
    Logger.info("Linear Agent turn completed for issue_id=#{issue_id} session_id=#{session_id}; idling issue room")
    initialize_linear_agent_comment_marker(issue_id)

    state
    |> complete_issue(issue_id)
    |> release_issue_claim(issue_id)
  end

  defp complete_normal_agent_run(%State{} = state, issue_id, running_entry, session_id) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

    state
    |> complete_issue(issue_id)
    |> schedule_issue_retry(issue_id, 1, %{
      identifier: running_entry.identifier,
      issue: Map.get(running_entry, :issue),
      delay_type: :continuation,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp maybe_store_linear_agent_thread(issue_id, %{mode: :linear_agent, thread_id: thread_id} = running_entry)
       when is_binary(issue_id) and is_binary(thread_id) do
    StateStore.put_issue(issue_id, %{
      thread_id: thread_id,
      agent_session_id: Map.get(running_entry, :agent_session_id),
      identifier: Map.get(running_entry, :identifier),
      workspace_path: Map.get(running_entry, :workspace_path),
      updated_at: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp maybe_store_linear_agent_thread(_issue_id, _running_entry), do: :ok

  defp initialize_linear_agent_comment_marker(issue_id) when is_binary(issue_id) do
    case Tracker.fetch_issue_comments(issue_id) do
      {:ok, comments} when is_list(comments) ->
        persist_latest_linear_agent_comment_marker(issue_id, comments)

      {:error, reason} ->
        Logger.debug("Unable to initialize Linear Agent comment marker for issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp initialize_linear_agent_comment_marker(_issue_id), do: :ok

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    issue = pick_retry_issue(previous_retry, metadata)
    pending_steering_comments = pick_retry_pending_steering(previous_retry, metadata)
    pending_review_comments = pick_retry_pending_review(previous_retry, metadata)
    retry_mode = pick_retry_mode(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue: issue,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            pending_steering_comments: pending_steering_comments,
            pending_review_comments: pending_review_comments,
            mode: retry_mode
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          issue: Map.get(retry_entry, :issue),
          pending_steering_comments: Map.get(retry_entry, :pending_steering_comments, []),
          pending_review_comments: Map.get(retry_entry, :pending_review_comments, []),
          mode: Map.get(retry_entry, :mode)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      review_comment_retry?(metadata) and waiting_for_human_review_state?(issue.state) ->
        if issue_paused_by_marker?(issue) do
          Logger.info("Skipping Human Review retry for paused issue: issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
          {:noreply, release_issue_claim(state, issue_id)}
        else
          handle_review_comment_retry(state, issue, attempt, metadata)
        end

      retry_candidate_issue?(issue, terminal_states) ->
        if issue_paused_by_marker?(issue) do
          Logger.info("Skipping active retry for paused issue: issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
          {:noreply, release_issue_claim(state, issue_id)}
        else
          handle_active_retry(state, issue, attempt, metadata)
        end

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp poll_comment_steering(%State{} = state) do
    do_poll_comment_steering(state)
  end

  defp do_poll_comment_steering(%State{} = state) do
    started_at = DateTime.utc_now()

    try do
      state
      |> Map.put(:last_linear_comment_poll_at, started_at)
      |> Map.put(:last_linear_comment_poll_error, nil)
      |> poll_running_issue_comments()
      |> poll_retrying_issue_comments()
      |> poll_human_review_issue_comments()
      |> Map.put(:last_successful_comment_poll_at, DateTime.utc_now())
    rescue
      exception ->
        Logger.warning("Linear comment polling failed: #{Exception.message(exception)}")

        %{
          state
          | last_linear_comment_poll_at: started_at,
            last_linear_comment_poll_error: Exception.message(exception)
        }
    end
  end

  defp poll_running_issue_comments(%State{} = state) do
    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      case Map.get(running_entry, :issue) do
        %Issue{} = issue -> poll_issue_comments(state_acc, issue_id, issue, {:running, running_entry})
        _ -> state_acc
      end
    end)
  end

  defp poll_retrying_issue_comments(%State{} = state) do
    Enum.reduce(state.retry_attempts, state, fn {issue_id, retry_entry}, state_acc ->
      case Map.get(retry_entry, :issue) do
        %Issue{} = issue -> poll_issue_comments(state_acc, issue_id, issue, {:retrying, retry_entry})
        _ -> state_acc
      end
    end)
  end

  defp poll_human_review_issue_comments(%State{} = state) do
    case Tracker.fetch_issues_by_states([@human_review_state]) do
      {:ok, issues} when is_list(issues) ->
        issues
        |> Enum.reduce(%{state | watched_human_review_count: length(issues)}, &poll_human_review_issue_comment/2)

      {:error, reason} ->
        Logger.debug("Failed to fetch Human Review issues for Linear comment polling: #{inspect(reason)}")
        %{state | last_linear_comment_poll_error: inspect(reason)}
    end
  end

  defp poll_human_review_issue_comment(%Issue{id: issue_id} = issue, %State{} = state)
       when is_binary(issue_id) do
    if issue_comment_poll_in_flight?(state, issue_id) do
      state
    else
      poll_issue_comments(state, issue_id, issue, {:human_review, %{}})
    end
  end

  defp poll_human_review_issue_comment(_issue, %State{} = state), do: state

  defp issue_comment_poll_in_flight?(%State{} = state, issue_id) when is_binary(issue_id) do
    Map.has_key?(state.running, issue_id) or Map.has_key?(state.retry_attempts, issue_id)
  end

  defp poll_issue_comments(%State{} = state, issue_id, %Issue{} = issue, entry)
       when is_binary(issue_id) do
    case Tracker.fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        handle_issue_comments(state, issue_id, issue, entry, comments)

      {:error, reason} ->
        Logger.debug("Failed to fetch Linear comments for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp issue_paused_by_marker?(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Tracker.fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        comments
        |> CommentSteering.find_status_comment()
        |> CommentSteering.marker_from_comment()
        |> case do
          {:ok, marker} -> CommentSteering.paused?(marker)
          _ -> false
        end

      {:error, reason} ->
        Logger.debug("Unable to read pause marker for issue_id=#{issue_id}: #{inspect(reason)}")
        false
    end
  end

  defp issue_paused_by_marker?(_issue), do: false

  defp handle_issue_comments(state, issue_id, issue, entry, comments) when is_list(comments) do
    if Config.settings!().linear_agent.enabled do
      handle_linear_agent_polled_issue_comments(state, issue_id, issue, entry, comments)
    else
      handle_status_comment_steering_issue_comments(state, issue_id, issue, entry, comments)
    end
  end

  defp handle_status_comment_steering_issue_comments(state, issue_id, issue, entry, comments) do
    status_comment = CommentSteering.find_status_comment(comments)
    marker_state = CommentSteering.marker_from_comment(status_comment)
    actionable_comments = CommentSteering.actionable_comments(comments, marker_state)

    cond do
      marker_state == :missing ->
        marker = CommentSteering.latest_marker(comments)

        :ok =
          upsert_status_comment(issue, status_comment, marker, last_update: "Initialized comment tracking.")

        state

      actionable_comments == [] ->
        state

      true ->
        process_actionable_comments_in_order(
          state,
          issue_id,
          issue,
          entry,
          status_comment,
          marker_state,
          actionable_comments
        )
    end
  end

  defp handle_linear_agent_polled_issue_comments(state, issue_id, issue, entry, comments) do
    marker_state = linear_agent_comment_marker_state(issue_id)
    actionable_comments = CommentSteering.actionable_comments(comments, marker_state)

    cond do
      marker_state == :missing ->
        persist_latest_linear_agent_comment_marker(issue_id, comments)
        state

      actionable_comments == [] ->
        state

      true ->
        process_linear_agent_polled_comments(state, issue_id, issue, entry, marker_state, actionable_comments)
    end
  end

  defp process_linear_agent_polled_comments(state, issue_id, issue, entry, {:ok, marker}, comments) do
    accumulator = %{
      state: state,
      marker: marker,
      worker_comments: []
    }

    comments
    |> Enum.reduce(accumulator, fn comment, acc ->
      if BridgeCommand.command?(comment) do
        acc
        |> flush_worker_comments(issue_id, issue, entry)
        |> process_linear_agent_polled_bridge_command(issue, comment)
      else
        process_linear_agent_polled_worker_comment(acc, issue.id, comment)
      end
    end)
    |> flush_worker_comments(issue_id, issue, entry)
    |> Map.fetch!(:state)
  end

  defp process_linear_agent_polled_comments(state, _issue_id, _issue, _entry, _marker_state, _comments), do: state

  defp process_linear_agent_polled_bridge_command(acc, %Issue{} = issue, %Comment{} = comment) do
    state =
      case BridgeCommand.parse(comment) do
        {:ok, command} -> apply_linear_agent_bridge_command(acc.state, issue, comment, command)
        {:error, :unknown_command, unknown} -> apply_unknown_linear_agent_bridge_command(acc.state, issue, comment, unknown)
        :not_command -> acc.state
      end

    marker =
      acc.marker
      |> CommentSteering.advance_marker(comment)
      |> Map.put(:paused, linear_agent_issue_paused?(issue.id))

    %{acc | state: state, marker: marker}
  end

  defp process_linear_agent_polled_worker_comment(acc, issue_id, %Comment{} = comment) do
    acknowledge_comment(comment)

    marker = CommentSteering.advance_marker(acc.marker, comment)

    case persist_linear_agent_comment_marker(marker, issue_id) do
      :ok ->
        if CommentSteering.paused?(marker) do
          Logger.info("Issue is paused; acknowledged non-command Linear comment without worker routing for issue_id=#{issue_id}")
          %{acc | marker: marker}
        else
          %{acc | marker: marker, worker_comments: acc.worker_comments ++ [comment]}
        end

      {:error, reason} ->
        Logger.warning("Skipping Linear Agent comment routing after local marker write failure for issue_id=#{issue_id}: #{inspect(reason)}")
        %{acc | marker: marker}
    end
  end

  defp process_actionable_comments_in_order(state, issue_id, issue, entry, status_comment, {:ok, marker}, comments) do
    accumulator = %{
      state: state,
      marker: marker,
      worker_comments: [],
      command_count: 0,
      worker_count: 0,
      paused_count: 0
    }

    comments
    |> Enum.reduce(accumulator, fn comment, acc ->
      if BridgeCommand.command?(comment) do
        acc
        |> flush_worker_comments(issue_id, issue, entry)
        |> process_bridge_command_comment(issue, status_comment, comment)
      else
        process_worker_comment(acc, issue, status_comment, comment)
      end
    end)
    |> flush_worker_comments(issue_id, issue, entry)
    |> Map.fetch!(:state)
  end

  defp process_actionable_comments_in_order(state, _issue_id, _issue, _entry, _status_comment, _marker_state, _comments), do: state

  defp process_bridge_command_comment(acc, %Issue{} = issue, status_comment, comment) do
    case BridgeCommand.parse(comment) do
      {:ok, command} ->
        acknowledge_comment(comment)
        {state, reply, paused?} = apply_bridge_command(acc.state, issue, command, acc.marker)

        marker =
          acc.marker
          |> CommentSteering.advance_marker(comment)
          |> CommentSteering.put_command(command.action_text, comment.id, paused: paused?)

        case upsert_status_comment(issue, status_comment, marker, last_update: "Saw Symphony command `#{command.action_text}`.") do
          :ok ->
            reply_to_bridge_command(issue, comment, reply)

            %{
              acc
              | state: %{state | last_bridge_command: bridge_command_snapshot(issue, comment, command)},
                marker: marker,
                command_count: acc.command_count + 1
            }

          {:error, reason} ->
            Logger.warning("Skipping Symphony command side effects after marker write failure for #{issue_context(issue)}: #{inspect(reason)}")
            acc
        end

      {:error, :unknown_command, unknown} ->
        acknowledge_comment(comment)

        marker =
          acc.marker
          |> CommentSteering.advance_marker(comment)
          |> CommentSteering.put_command("unknown", comment.id, paused: CommentSteering.paused?(acc.marker))

        case upsert_status_comment(issue, status_comment, marker, last_update: "Saw unknown Symphony command.") do
          :ok ->
            reply_to_bridge_command(issue, comment, "Unknown Symphony command `#{unknown}`. #{BridgeCommand.help_text()}")

            %{
              acc
              | state: %{
                  acc.state
                  | last_bridge_command: %{
                      issue_id: issue.id,
                      issue_identifier: issue.identifier,
                      comment_id: comment.id,
                      command: "unknown",
                      at: DateTime.utc_now()
                    }
                },
                marker: marker,
                command_count: acc.command_count + 1
            }

          {:error, reason} ->
            Logger.warning("Skipping unknown Symphony command reply after marker write failure for #{issue_context(issue)}: #{inspect(reason)}")
            acc
        end

      :not_command ->
        acc
    end
  end

  defp process_worker_comment(acc, %Issue{} = issue, status_comment, comment) do
    acknowledge_comment(comment)
    marker = CommentSteering.advance_marker(acc.marker, comment)
    paused? = CommentSteering.paused?(marker)

    case upsert_status_comment(issue, status_comment, marker,
           last_update:
             if(paused?,
               do: "Saw a non-command comment while paused.",
               else: "Saw a worker-routed Linear comment."
             )
         ) do
      :ok ->
        if paused? do
          Logger.info("Issue is paused; acknowledged non-command Linear comment without worker routing for #{issue_context(issue)}")
          %{acc | marker: marker, worker_count: acc.worker_count + 1, paused_count: acc.paused_count + 1}
        else
          %{acc | marker: marker, worker_comments: acc.worker_comments ++ [comment], worker_count: acc.worker_count + 1}
        end

      {:error, reason} ->
        Logger.warning("Skipping Linear comment routing after marker write failure for #{issue_context(issue)}: #{inspect(reason)}")
        acc
    end
  end

  defp flush_worker_comments(%{worker_comments: []} = acc, _issue_id, _issue, _entry), do: acc

  defp flush_worker_comments(%{worker_comments: worker_comments} = acc, issue_id, issue, entry) do
    steering_message = CommentSteering.format_steering_message(worker_comments)
    state = route_comment_steering(acc.state, issue_id, issue, entry, worker_comments, steering_message)
    %{acc | state: state, worker_comments: []}
  end

  defp apply_bridge_command(%State{} = state, _issue, %{action: :help}, marker) do
    {state, BridgeCommand.help_text(), CommentSteering.paused?(marker)}
  end

  defp apply_bridge_command(%State{} = state, %Issue{} = issue, %{action: :status}, marker) do
    paused? = CommentSteering.paused?(marker)

    reply =
      [
        "Status: #{issue.state || "Unknown"}.",
        if(paused?, do: "Paused: yes.", else: "Paused: no."),
        if(Map.has_key?(state.running, issue.id), do: "Run: active.", else: nil),
        if(Map.has_key?(state.retry_attempts, issue.id), do: "Retry: queued.", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    {state, reply, paused?}
  end

  defp apply_bridge_command(%State{} = state, %Issue{} = issue, %{action: :pause}, _marker) do
    state = stop_issue_runtime(state, issue.id)
    {state, "Paused. I will keep acknowledging comments, but will not route non-command comments until `symphony resume`.", true}
  end

  defp apply_bridge_command(%State{} = state, _issue, %{action: :resume}, _marker) do
    {state, "Resumed. New non-command comments can route to the worker again.", false}
  end

  defp apply_bridge_command(%State{} = state, %Issue{} = issue, %{action: :cancel}, _marker) do
    state = stop_issue_runtime(state, issue.id)
    {state, "Canceled the active Symphony runtime for this issue and left the workspace intact. Use `symphony resume` when you want routing again.", true}
  end

  defp apply_bridge_command(%State{} = state, %Issue{} = issue, %{action: :retry}, marker) do
    case Map.get(state.retry_attempts, issue.id) do
      %{retry_token: retry_token} = retry_entry ->
        if is_reference(Map.get(retry_entry, :timer_ref)) do
          Process.cancel_timer(retry_entry.timer_ref)
        end

        Process.send_after(self(), {:retry_issue, issue.id, retry_token}, 0)
        {state, "Retry queued now.", CommentSteering.paused?(marker)}

      _ ->
        {state, "No retry is queued for this issue right now.", CommentSteering.paused?(marker)}
    end
  end

  defp reply_to_bridge_command(%Issue{id: issue_id}, %{id: comment_id}, body)
       when is_binary(issue_id) and is_binary(comment_id) and is_binary(body) do
    case Tracker.create_comment_reply(issue_id, comment_id, body) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("Unable to reply to Symphony bridge command #{comment_id}: #{inspect(reason)}")
    end
  end

  defp reply_to_bridge_command(_issue, _comment, _body), do: :ok

  defp bridge_command_snapshot(%Issue{} = issue, comment, command) do
    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      comment_id: comment.id,
      command: command.action_text,
      at: DateTime.utc_now()
    }
  end

  defp stop_issue_runtime(%State{} = state, issue_id) when is_binary(issue_id) do
    state
    |> terminate_running_issue(issue_id, false)
    |> cancel_retry(issue_id)
    |> release_issue_claim(issue_id)
  end

  defp cancel_retry(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _ -> :ok
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  defp acknowledge_comment(%{id: comment_id}) when is_binary(comment_id) do
    case Tracker.create_comment_reaction(comment_id, "eyes") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("Unable to add eyes reaction to Linear comment #{comment_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp upsert_status_comment(%Issue{id: issue_id} = issue, status_comment, marker, opts)
       when is_binary(issue_id) and is_map(marker) do
    body = CommentSteering.build_status_body(issue, marker, opts)

    case status_comment do
      %{id: comment_id} when is_binary(comment_id) ->
        case Tracker.update_comment(comment_id, body) do
          :ok -> :ok
          {:error, reason} -> log_status_comment_error(issue, :update, reason)
        end

      _ ->
        case Tracker.create_comment(issue_id, body) do
          :ok -> :ok
          {:error, reason} -> log_status_comment_error(issue, :create, reason)
        end
    end
  end

  defp log_status_comment_error(issue, operation, reason) do
    Logger.debug("Unable to #{operation} Symphony status comment for #{issue_context(issue)}: #{inspect(reason)}")
    {:error, reason}
  end

  defp route_comment_steering(%State{} = state, issue_id, %Issue{} = issue, {:running, %{mode: :review_comment}}, comments, message) do
    Logger.info("Queued #{length(comments)} Human Review comment(s) for active review run on #{issue_context(issue)}")

    update_running_entry(state, issue_id, %{
      last_linear_comment_steered_at: DateTime.utc_now(),
      pending_review_comments: comments,
      pending_steering_comments: [message]
    })
  end

  defp route_comment_steering(%State{} = state, issue_id, _issue, {:running, running_entry}, _comments, message) do
    if is_pid(running_entry.pid) do
      if running_turn_active?(running_entry) do
        send(running_entry.pid, {:symphony_steer, message})
      else
        send(running_entry.pid, {:symphony_queue_steering, message})
      end
    end

    update_running_entry(state, issue_id, %{
      last_linear_comment_steered_at: DateTime.utc_now()
    })
  end

  defp route_comment_steering(%State{} = state, issue_id, _issue, {:retrying, retry_entry}, _comments, message) do
    retry_entry =
      Map.update(retry_entry, :pending_steering_comments, [message], fn existing ->
        existing ++ [message]
      end)

    %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, retry_entry)}
  end

  defp route_comment_steering(%State{} = state, _issue_id, %Issue{} = issue, {:human_review, _entry}, comments, _message) do
    if Config.settings!().linear_agent.enabled do
      route_linear_agent_polled_comments(state, issue, comments)
    else
      dispatch_review_comment_issue(state, issue, comments)
    end
  end

  defp route_linear_agent_polled_comments(%State{} = state, %Issue{} = issue, comments) do
    issue_state = StateStore.get_issue(issue.id)

    agent_session_id =
      Map.get(issue_state, "agent_session_id") ||
        get_in(state.running, [issue.id, :agent_session_id]) ||
        latest_agent_session_id_for_issue(issue)

    if is_binary(agent_session_id) and agent_session_id != "" do
      Logger.info("Routing #{length(comments)} Linear issue comment(s) into native AgentSession for #{issue_context(issue)}")
      persist_linear_agent_session_id(issue.id, agent_session_id)

      handle_linear_agent_session_event(state, %{
        action: "prompted",
        agent_session_id: agent_session_id,
        issue: issue,
        prompt_body: linear_agent_comment_batch_prompt(comments),
        prompt_context: nil
      })
    else
      Logger.info("Ignoring non-command Linear issue comment without known AgentSession for #{issue_context(issue)}")
      state
    end
  end

  defp persist_linear_agent_session_id(issue_id, agent_session_id)
       when is_binary(issue_id) and is_binary(agent_session_id) and agent_session_id != "" do
    case StateStore.put_issue(issue_id, %{
           agent_session_id: agent_session_id,
           updated_at: DateTime.to_iso8601(DateTime.utc_now())
         }) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to persist Linear AgentSession id for issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp persist_linear_agent_session_id(_issue_id, _agent_session_id), do: :ok

  defp running_turn_active?(%{pid: pid, thread_id: thread_id, active_turn_id: active_turn_id})
       when is_pid(pid) and is_binary(thread_id) and is_binary(active_turn_id),
       do: Process.alive?(pid)

  defp running_turn_active?(_running_entry), do: false

  defp update_running_entry(%State{} = state, issue_id, updates) when is_map(updates) do
    case Map.get(state.running, issue_id) do
      nil -> state
      running_entry -> %{state | running: Map.put(state.running, issue_id, merge_running_entry_updates(running_entry, updates))}
    end
  end

  defp merge_running_entry_updates(running_entry, updates) do
    Enum.reduce(updates, running_entry, fn
      {:pending_review_comments, comments}, entry when is_list(comments) ->
        Map.update(entry, :pending_review_comments, comments, &append_list(&1, comments))

      {:pending_steering_comments, messages}, entry when is_list(messages) ->
        Map.update(entry, :pending_steering_comments, messages, &append_list(&1, messages))

      {key, value}, entry ->
        Map.put(entry, key, value)
    end)
  end

  defp append_list(existing, additions) when is_list(existing), do: existing ++ additions
  defp append_list(_existing, additions), do: additions

  defp maybe_run_terminal_workspace_cleanup(%{linear_agent: %{enabled: true}}) do
    Logger.info("Skipping terminal workspace cleanup in Linear Agent mode")
    :ok
  end

  defp maybe_run_terminal_workspace_cleanup(_config) do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      runner_opts = [steering_comments: metadata[:pending_steering_comments] || []]

      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], runner_opts)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           issue: issue,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp handle_review_comment_retry(state, issue, attempt, metadata) do
    comments = metadata[:pending_review_comments] || []

    if dispatch_slots_available?(issue, state) and worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_review_comment_issue(state, issue, comments)}
    else
      Logger.debug("No available slots for retrying Human Review comments for #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           issue: issue,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp review_comment_retry?(metadata) when is_map(metadata), do: metadata[:mode] == :review_comment

  defp human_review_worker_continues?(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{mode: mode} when mode in [:review_comment, :linear_agent] -> true
      _ -> false
    end
  end

  defp human_review_worker_continues?(_state, _issue_id), do: false

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    cond do
      metadata[:delay_type] == :continuation and attempt == 1 ->
        @continuation_retry_delay_ms

      metadata[:delay_type] == :review_comment and attempt == 1 ->
        @continuation_retry_delay_ms

      true ->
        failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_issue(previous_retry, metadata) do
    metadata[:issue] || Map.get(previous_retry, :issue)
  end

  defp pick_retry_pending_steering(previous_retry, metadata) do
    metadata[:pending_steering_comments] || Map.get(previous_retry, :pending_steering_comments, [])
  end

  defp pick_retry_pending_review(previous_retry, metadata) do
    metadata[:pending_review_comments] || Map.get(previous_retry, :pending_review_comments, [])
  end

  defp pick_retry_mode(previous_retry, metadata) do
    metadata[:mode] || Map.get(previous_retry, :mode)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          mode: Map.get(metadata, :mode, :normal),
          pending_review_comment_count: length(Map.get(metadata, :pending_review_comments, [])),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    paused_issue_ids = paused_issue_ids_from_runtime(state)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       bridge: %{
         paused_issue_ids: paused_issue_ids,
         paused_count: length(paused_issue_ids),
         last_command: bridge_command_snapshot_for_payload(state.last_bridge_command)
       },
       comment_polling: %{
         last_poll_at: state.last_linear_comment_poll_at,
         last_successful_poll_at: state.last_successful_comment_poll_at,
         last_error: state.last_linear_comment_poll_error,
         watched_human_review_count: state.watched_human_review_count
       },
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp paused_issue_ids_from_runtime(%State{} = state) do
    []
    |> Kernel.++(paused_issue_ids_from_entries(state.running))
    |> Kernel.++(paused_issue_ids_from_entries(state.retry_attempts))
    |> Enum.uniq()
  end

  defp paused_issue_ids_from_entries(entries) when is_map(entries) do
    entries
    |> Enum.flat_map(fn
      {issue_id, %{issue: %Issue{} = issue}} ->
        if issue_paused_by_marker?(issue), do: [issue_id], else: []

      _ ->
        []
    end)
  end

  defp bridge_command_snapshot_for_payload(nil), do: nil

  defp bridge_command_snapshot_for_payload(%{at: %DateTime{} = at} = command) do
    %{command | at: DateTime.to_iso8601(at)}
  end

  defp bridge_command_snapshot_for_payload(command), do: command

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    thread_id = Map.get(running_entry, :thread_id)
    active_turn_id = Map.get(running_entry, :active_turn_id)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        thread_id: thread_id_for_update(thread_id, update),
        active_turn_id: active_turn_id_for_update(active_turn_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp thread_id_for_update(_existing, %{thread_id: thread_id}) when is_binary(thread_id),
    do: thread_id

  defp thread_id_for_update(existing, _update), do: existing

  defp active_turn_id_for_update(_existing, %{event: :session_started, turn_id: turn_id})
       when is_binary(turn_id),
       do: turn_id

  defp active_turn_id_for_update(_existing, %{event: event})
       when event in [:turn_completed, :turn_failed, :turn_cancelled, :turn_ended_with_error],
       do: nil

  defp active_turn_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_comment_poll(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.comment_timer_ref) do
      Process.cancel_timer(state.comment_timer_ref)
    end

    comment_poll_token = make_ref()
    timer_ref = Process.send_after(self(), {:poll_comments, comment_poll_token}, delay_ms)

    %{
      state
      | comment_timer_ref: timer_ref,
        comment_poll_token: comment_poll_token
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      dispatchable_issue_state?(issue.state) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
