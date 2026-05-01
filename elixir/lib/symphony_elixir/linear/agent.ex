defmodule SymphonyElixir.Linear.Agent do
  @moduledoc """
  Linear AgentSession helpers and webhook normalization.
  """

  alias SymphonyElixir.Linear.{Client, Comment, Issue}

  @activity_mutation """
  mutation SymphonyAgentActivityCreate($input: AgentActivityCreateInput!) {
    agentActivityCreate(input: $input) {
      success
      agentActivity {
        id
      }
    }
  }
  """

  @session_update_mutation """
  mutation SymphonyAgentSessionUpdate($agentSessionId: String!, $input: AgentSessionUpdateInput!) {
    agentSessionUpdate(id: $agentSessionId, input: $input) {
      success
    }
  }
  """

  @states_query """
  query SymphonyRequiredStates {
    teams {
      nodes {
        id
        name
        states {
          nodes {
            name
          }
        }
      }
    }
  }
  """

  @type event :: %{
          action: String.t(),
          agent_session_id: String.t() | nil,
          prompt_context: String.t() | nil,
          prompt_body: String.t() | nil,
          comment: Comment.t() | nil,
          issue: Issue.t() | nil,
          raw: map()
        }

  @spec normalize_webhook(map()) :: {:ok, event()} | {:error, term()}
  def normalize_webhook(%{} = payload) do
    {:ok,
     %{
       action: string_at(payload, ["action"]) || "",
       agent_session_id: payload |> webhook_session() |> string_at(["id"]),
       prompt_context: webhook_prompt_context(payload),
       prompt_body: payload |> webhook_activity() |> activity_body(),
       comment: normalize_comment(payload),
       issue: payload |> webhook_issue() |> normalize_issue(),
       raw: payload
     }}
  end

  def normalize_webhook(_payload), do: {:error, :invalid_agent_session_payload}

  @spec create_activity(String.t(), map()) :: :ok | {:error, term()}
  def create_activity(agent_session_id, content) when is_binary(agent_session_id) and is_map(content) do
    with {:ok, response} <-
           Client.graphql(@activity_mutation, %{
             "input" => %{"agentSessionId" => agent_session_id, "content" => content}
           }),
         true <- get_in(response, ["data", "agentActivityCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :agent_activity_create_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_session(String.t(), map()) :: :ok | {:error, term()}
  def update_session(agent_session_id, input) when is_binary(agent_session_id) and is_map(input) do
    with {:ok, response} <- Client.graphql(@session_update_mutation, %{agentSessionId: agent_session_id, input: input}),
         true <- get_in(response, ["data", "agentSessionUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :agent_session_update_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_required_statuses([String.t()]) :: :ok | {:error, map()}
  def validate_required_statuses(required_statuses) when is_list(required_statuses) do
    with {:ok, response} <- Client.graphql(@states_query, %{}) do
      missing_by_team =
        response
        |> get_in(["data", "teams", "nodes"])
        |> List.wrap()
        |> Enum.flat_map(&missing_statuses_for_team(&1, required_statuses))

      if missing_by_team == [], do: :ok, else: {:error, %{missing_statuses: missing_by_team}}
    end
  end

  defp webhook_session(payload) do
    map_at(payload, ["agentSession"]) || map_at(payload, ["data", "agentSession"]) || map_at(payload, ["data"]) || %{}
  end

  defp webhook_activity(payload) do
    map_at(payload, ["agentActivity"]) || map_at(payload, ["data", "agentActivity"]) || %{}
  end

  defp webhook_issue(payload) do
    session = webhook_session(payload)

    map_at(session, ["issue"]) ||
      map_at(payload, ["issue"]) ||
      map_at(payload, ["data", "issue"]) ||
      map_at(payload, ["notification", "issue"])
  end

  defp webhook_prompt_context(payload) do
    string_at(webhook_session(payload), ["promptContext"]) || string_at(payload, ["promptContext"])
  end

  defp activity_body(activity) do
    string_at(activity, ["body"]) || string_at(activity, ["content", "body"])
  end

  defp normalize_comment(%{} = payload) do
    with %{} = notification <- map_at(payload, ["notification"]),
         %{} = comment <- map_at(notification, ["comment"]),
         id when is_binary(id) <- string_at(comment, ["id"]) do
      actor = map_at(notification, ["actor"]) || %{}
      app_user_id = string_at(payload, ["appUserId"])
      author_id = string_at(comment, ["userId"]) || string_at(notification, ["actorId"])

      %Comment{
        id: id,
        body: string_at(comment, ["body"]),
        created_at: parse_datetime(string_at(comment, ["createdAt"]) || string_at(notification, ["createdAt"])),
        updated_at: parse_datetime(string_at(comment, ["updatedAt"]) || string_at(notification, ["updatedAt"])),
        author_id: author_id,
        author_name: string_at(actor, ["name"]),
        parent_id: string_at(notification, ["parentCommentId"]) || string_at(comment, ["parentId"]),
        author_is_bot: is_binary(app_user_id) and author_id == app_user_id
      }
    else
      _ -> nil
    end
  end

  defp missing_statuses_for_team(%{"name" => team_name, "states" => %{"nodes" => states}}, required_statuses) do
    state_names = states |> List.wrap() |> Enum.map(&Map.get(&1, "name")) |> MapSet.new()

    case Enum.reject(required_statuses, &MapSet.member?(state_names, &1)) do
      [] -> []
      missing -> [%{team: team_name, missing: missing}]
    end
  end

  defp missing_statuses_for_team(_team, _required_statuses), do: []

  defp normalize_issue(nil), do: nil

  defp normalize_issue(%{} = issue) do
    state = map_at(issue, ["state"])

    %Issue{
      id: string_at(issue, ["id"]),
      identifier: string_at(issue, ["identifier"]),
      title: string_at(issue, ["title"]) || "Linear Agent Session",
      description: string_at(issue, ["description"]),
      priority: nil,
      state: string_at(state || %{}, ["name"]),
      branch_name: string_at(issue, ["branchName"]),
      url: string_at(issue, ["url"]),
      labels: issue |> list_at(["labels", "nodes"]) |> Enum.flat_map(&label_name/1),
      assigned_to_worker: true,
      created_at: parse_datetime(string_at(issue, ["createdAt"])),
      updated_at: parse_datetime(string_at(issue, ["updatedAt"]))
    }
  end

  defp map_at(map, path) when is_map(map) do
    case get_in(map, path) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp string_at(map, path) when is_map(map) do
    case get_in(map, path) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp list_at(map, path) when is_map(map) do
    case get_in(map, path) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp label_name(%{"name" => name}) when is_binary(name), do: [String.downcase(name)]
  defp label_name(_label), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
