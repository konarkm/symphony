defmodule SymphonyElixir.Linear.CommentSteering do
  @moduledoc """
  Comment filtering and compact status comment helpers for Linear steering.
  """

  alias SymphonyElixir.Linear.{Comment, Issue}

  @status_heading "## Symphony Status"
  @marker_prefix "<!-- symphony:comments "
  @marker_suffix " -->"
  @marker_regex ~r/<!--\s*symphony:comments\s+({.*?})\s*-->/s

  @type marker :: %{
          optional(:last_seen_comment_id) => String.t(),
          optional(:last_seen_comment_updated_at) => String.t()
        }

  @spec status_heading() :: String.t()
  def status_heading, do: @status_heading

  @spec status_comment?(Comment.t()) :: boolean()
  def status_comment?(%Comment{body: body}) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?(@status_heading)
  end

  def status_comment?(_comment), do: false

  @spec find_status_comment([Comment.t()]) :: Comment.t() | nil
  def find_status_comment(comments) when is_list(comments) do
    Enum.find(comments, &status_comment?/1)
  end

  @spec parse_marker(String.t() | nil) :: {:ok, marker()} | :missing | :invalid
  def parse_marker(body) when is_binary(body) do
    case Regex.run(@marker_regex, body) do
      [_match, json] ->
        decode_marker(json)

      _ ->
        :missing
    end
  end

  def parse_marker(_body), do: :missing

  defp decode_marker(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, marker} when is_map(marker) ->
        marker
        |> normalize_marker()
        |> valid_marker_result()

      _ ->
        :invalid
    end
  end

  @spec marker_from_comment(Comment.t() | nil) :: {:ok, marker()} | :missing | :invalid
  def marker_from_comment(%Comment{body: body}), do: parse_marker(body)
  def marker_from_comment(_comment), do: :missing

  @spec marker_for_comment(Comment.t()) :: marker()
  def marker_for_comment(%Comment{id: id} = comment) do
    %{
      last_seen_comment_id: id,
      last_seen_comment_updated_at: comment_timestamp_iso8601(comment)
    }
  end

  @spec latest_marker([Comment.t()]) :: marker()
  def latest_marker(comments) when is_list(comments) do
    case latest_comment(comments) do
      %Comment{} = comment ->
        marker_for_comment(comment)

      nil ->
        %{
          last_seen_comment_id: "",
          last_seen_comment_updated_at: DateTime.to_iso8601(DateTime.utc_now())
        }
    end
  end

  @spec actionable_comments([Comment.t()], {:ok, marker()} | :missing | :invalid) :: [Comment.t()]
  def actionable_comments(comments, {:ok, marker}) when is_list(comments) and is_map(marker) do
    comments
    |> Enum.reject(&ignored_comment?/1)
    |> Enum.filter(&newer_than_marker?(&1, marker))
    |> sort_comments()
  end

  def actionable_comments(comments, _marker_state) when is_list(comments), do: []

  @spec format_steering_message([Comment.t()]) :: String.t()
  def format_steering_message(comments) when is_list(comments) do
    comments
    |> sort_comments()
    |> Enum.map_join("\n", fn comment ->
      author = comment.author_name || "Human"
      body = comment.body |> to_string() |> String.trim()
      "- #{author}: #{body}"
    end)
    |> then(fn rendered ->
      """
      New Linear comment context arrived. Treat it as actionable steering and adjust only if useful.

      #{rendered}
      """
      |> String.trim()
    end)
  end

  @spec format_review_context([Comment.t()]) :: String.t()
  def format_review_context(comments) when is_list(comments) do
    comments
    |> sort_comments()
    |> Enum.map_join("\n", fn comment ->
      author = comment.author_name || "Human"
      body = comment.body |> to_string() |> String.trim()
      "- comment_id=#{comment.id} parent_id=#{comment.parent_id || "none"} author=#{author}: #{body}"
    end)
  end

  @spec continuation_context([Comment.t()] | [String.t()]) :: String.t()
  def continuation_context(messages) when is_list(messages) do
    messages
    |> Enum.map(&continuation_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec build_status_body(Issue.t(), marker(), keyword()) :: String.t()
  def build_status_body(%Issue{} = issue, marker, opts \\ []) when is_map(marker) do
    plan = Keyword.get(opts, :plan, "Follow the issue, watch Linear comments, and keep updates compact.")
    blockers = Keyword.get(opts, :blockers, "None known.")
    validation = Keyword.get(opts, :validation, "Not run yet.")
    last_update = Keyword.get(opts, :last_update, "Watching Linear for new human comments.")

    [
      @status_heading,
      "",
      "- Status: #{issue.state || "Unknown"}",
      "- Plan: #{plan}",
      "- Blockers: #{blockers}",
      "- Validation: #{validation}",
      "- Last update: #{last_update}",
      "",
      marker_comment(marker)
    ]
    |> Enum.join("\n")
  end

  @spec latest_comment([Comment.t()]) :: Comment.t() | nil
  def latest_comment(comments) when is_list(comments) do
    comments
    |> sort_comments()
    |> List.last()
  end

  defp normalize_marker(marker) when is_map(marker) do
    %{
      last_seen_comment_id: Map.get(marker, "last_seen_comment_id") || Map.get(marker, :last_seen_comment_id),
      last_seen_comment_updated_at: Map.get(marker, "last_seen_comment_updated_at") || Map.get(marker, :last_seen_comment_updated_at)
    }
  end

  defp valid_marker?(%{last_seen_comment_id: id, last_seen_comment_updated_at: updated_at})
       when is_binary(id) and is_binary(updated_at) do
    match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(updated_at))
  end

  defp valid_marker?(_marker), do: false

  defp valid_marker_result(marker) do
    if valid_marker?(marker), do: {:ok, marker}, else: :invalid
  end

  defp marker_comment(marker) when is_map(marker) do
    encoded_marker =
      marker
      |> Map.take([:last_seen_comment_id, :last_seen_comment_updated_at])
      |> Jason.encode!()

    @marker_prefix <> encoded_marker <> @marker_suffix
  end

  defp ignored_comment?(%Comment{author_is_bot: true}), do: true
  defp ignored_comment?(%Comment{parent_id: parent_id}) when is_binary(parent_id), do: true

  defp ignored_comment?(%Comment{body: body}) do
    blank?(body) or status_body?(body)
  end

  defp blank?(body) when is_binary(body), do: String.trim(body) == ""
  defp blank?(_body), do: true

  defp status_body?(body) when is_binary(body) do
    trimmed = String.trim_leading(body)
    String.starts_with?(trimmed, @status_heading) or String.contains?(body, "<!-- symphony:")
  end

  defp newer_than_marker?(%Comment{} = comment, marker) do
    with %DateTime{} = comment_time <- comment_timestamp(comment),
         marker_time when is_binary(marker_time) <- marker[:last_seen_comment_updated_at],
         {:ok, marker_datetime, _offset} <- DateTime.from_iso8601(marker_time) do
      case DateTime.compare(comment_time, marker_datetime) do
        :gt -> true
        :lt -> false
        :eq -> comment.id > to_string(marker[:last_seen_comment_id] || "")
      end
    else
      _ -> false
    end
  end

  defp comment_timestamp_iso8601(%Comment{} = comment) do
    case comment_timestamp(comment) do
      %DateTime{} = timestamp -> DateTime.to_iso8601(timestamp)
      _ -> nil
    end
  end

  defp comment_timestamp(%Comment{updated_at: %DateTime{} = updated_at}), do: updated_at
  defp comment_timestamp(%Comment{created_at: %DateTime{} = created_at}), do: created_at
  defp comment_timestamp(_comment), do: nil

  defp sort_comments(comments) when is_list(comments) do
    Enum.sort_by(comments, fn %Comment{id: id} = comment ->
      timestamp =
        case comment_timestamp(comment) do
          %DateTime{} = datetime -> DateTime.to_unix(datetime, :microsecond)
          _ -> 0
        end

      {timestamp, id}
    end)
  end

  defp continuation_line(%Comment{} = comment) do
    author = comment.author_name || "Human"
    body = comment.body |> to_string() |> String.trim()
    "- #{author}: #{body}"
  end

  defp continuation_line(message) when is_binary(message), do: String.trim(message)
  defp continuation_line(_message), do: ""
end
