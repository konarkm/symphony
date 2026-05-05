defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{Client, Comment}

  @comment_page_size 50

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @create_comment_reply_mutation """
  mutation SymphonyCreateCommentReply($issueId: String!, $parentId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, parentId: $parentId, body: $body}) {
      success
    }
  }
  """

  @comments_query """
  query SymphonyIssueComments($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      comments(first: $first) {
        nodes {
          id
          body
          parentId
          createdAt
          updatedAt
          user {
            id
            name
            displayName
            isMe
          }
        }
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
    }
  }
  """

  @create_reaction_mutation """
  mutation SymphonyCreateReaction($commentId: String!, $emoji: String!) {
    reactionCreate(input: {commentId: $commentId, emoji: $emoji}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec fetch_issue_comments(String.t()) :: {:ok, [Comment.t()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    with {:ok, response} <-
           client_module().graphql(@comments_query, %{issueId: issue_id, first: @comment_page_size}),
         comments when is_list(comments) <- get_in(response, ["data", "issue", "comments", "nodes"]) do
      {:ok, Enum.flat_map(comments, &normalize_comment/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comments_fetch_failed}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec create_comment_reply(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment_reply(issue_id, parent_id, body)
      when is_binary(issue_id) and is_binary(parent_id) and is_binary(body) do
    with {:ok, response} <-
           client_module().graphql(@create_comment_reply_mutation, %{
             issueId: issue_id,
             parentId: parent_id,
             body: body
           }),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_reply_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_reply_create_failed}
    end
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@update_comment_mutation, %{commentId: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  @spec create_comment_reaction(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment_reaction(comment_id, emoji) when is_binary(comment_id) and is_binary(emoji) do
    with {:ok, response} <-
           client_module().graphql(@create_reaction_mutation, %{commentId: comment_id, emoji: emoji}),
         true <- get_in(response, ["data", "reactionCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :reaction_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :reaction_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp normalize_comment(%{"id" => id} = comment) when is_binary(id) do
    user = Map.get(comment, "user") || %{}

    [
      %Comment{
        id: id,
        body: Map.get(comment, "body"),
        created_at: parse_datetime(Map.get(comment, "createdAt")),
        updated_at: parse_datetime(Map.get(comment, "updatedAt")),
        author_id: Map.get(user, "id"),
        author_name: Map.get(user, "displayName") || Map.get(user, "name"),
        parent_id: Map.get(comment, "parentId"),
        author_is_bot: author_is_current_linear_agent?(user)
      }
    ]
  end

  defp normalize_comment(_comment), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp author_is_current_linear_agent?(user) when is_map(user) do
    Map.get(user, "isMe") == true and linear_agent_enabled?()
  end

  defp linear_agent_enabled? do
    Config.settings!().linear_agent.enabled
  end
end
