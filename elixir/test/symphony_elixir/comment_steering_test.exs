defmodule SymphonyElixir.CommentSteeringTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{Comment, CommentSteering}

  test "reads and writes hidden last-seen markers in compact status comments" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    marker = %{last_seen_comment_id: "comment-1", last_seen_comment_updated_at: "2026-04-28T01:00:00Z", paused: true}

    body = CommentSteering.build_status_body(issue, marker)

    assert body =~ "## Symphony Status"
    assert body =~ "- Status: In Progress"
    assert {:ok, ^marker} = CommentSteering.parse_marker(body)
    assert CommentSteering.status_heading() == "## Symphony Status"
    assert CommentSteering.status_comment?(%Comment{id: "status", body: body})
    refute CommentSteering.status_comment?(%Comment{id: "human", body: "plain comment"})
    refute CommentSteering.status_comment?(:not_a_comment)
    assert CommentSteering.find_status_comment([%Comment{id: "human", body: "plain comment"}, %Comment{id: "status", body: body}]).id == "status"
  end

  test "filters bot and symphony-generated comments and sorts human comments by timestamp and id" do
    marker = %{last_seen_comment_id: "comment-1", last_seen_comment_updated_at: "2026-04-28T01:00:00Z"}

    comments = [
      comment("comment-4", "2026-04-28T01:02:00Z", "later"),
      comment("comment-0", "2026-04-27T23:00:00Z", "too old"),
      comment("comment-3", "2026-04-28T01:01:00Z", "bot", bot?: true),
      comment("comment-2", "2026-04-28T01:01:00Z", "## Symphony Status\n<!-- symphony:comments {} -->"),
      %Comment{comment("comment-reply", "2026-04-28T01:03:00Z", "thread reply") | parent_id: "comment-3b"},
      comment("comment-empty", "2026-04-28T01:01:00Z", nil),
      comment("comment-1", "2026-04-28T01:00:00Z", "old"),
      comment("comment-3b", "2026-04-28T01:01:00Z", "first human"),
      comment("comment-3c", "2026-04-28T01:01:00Z", "second human")
    ]

    assert CommentSteering.actionable_comments(comments, {:ok, marker}) == [
             comment("comment-3b", "2026-04-28T01:01:00Z", "first human"),
             comment("comment-3c", "2026-04-28T01:01:00Z", "second human"),
             comment("comment-4", "2026-04-28T01:02:00Z", "later")
           ]
  end

  test "missing or invalid marker treats existing comments conservatively" do
    comments = [comment("comment-1", "2026-04-28T01:00:00Z", "please change this")]

    assert CommentSteering.actionable_comments(comments, :missing) == []
    assert CommentSteering.actionable_comments(comments, :invalid) == []

    assert CommentSteering.latest_marker(comments) == %{
             last_seen_comment_id: "comment-1",
             last_seen_comment_updated_at: "2026-04-28T01:00:00Z",
             paused: false
           }

    assert %{last_seen_comment_id: "", last_seen_comment_updated_at: timestamp} = CommentSteering.latest_marker([])
    assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(timestamp)
    assert CommentSteering.parse_marker("plain comment") == :missing
    assert CommentSteering.parse_marker(nil) == :missing
    assert CommentSteering.parse_marker("<!-- symphony:comments {nope} -->") == :invalid
    assert CommentSteering.parse_marker("<!-- symphony:comments {} -->") == :invalid
    assert CommentSteering.marker_from_comment(%Comment{id: "status", body: "<!-- symphony:comments {} -->"}) == :invalid
    assert CommentSteering.marker_from_comment(nil) == :missing
  end

  test "preserves pause and command marker metadata while advancing comments" do
    {:ok, at, _offset} = DateTime.from_iso8601("2026-04-28T01:01:00Z")
    comment = %Comment{id: "comment-2", body: "new", created_at: at, updated_at: at}

    marker =
      %{last_seen_comment_id: "comment-1", last_seen_comment_updated_at: "2026-04-28T01:00:00Z", paused: true}
      |> CommentSteering.put_command("pause", "command-1", at: at, paused: true)
      |> CommentSteering.advance_marker(comment)

    body = CommentSteering.build_status_body(%Issue{id: "issue-1", state: "In Progress"}, marker)

    assert {:ok,
            %{
              last_seen_comment_id: "comment-2",
              last_seen_comment_updated_at: "2026-04-28T01:01:00Z",
              paused: true,
              last_command: "pause",
              last_command_comment_id: "command-1",
              last_command_at: "2026-04-28T01:01:00Z"
            }} = CommentSteering.parse_marker(body)
  end

  test "command marker helpers accept optional metadata shapes" do
    marker = %{
      last_seen_comment_id: "comment-1",
      last_seen_comment_updated_at: "2026-04-28T01:00:00Z"
    }

    marker_without_pause = CommentSteering.put_command(marker, "status", "command-1")
    refute Map.has_key?(marker_without_pause, :paused)
    refute CommentSteering.paused?(marker_without_pause)
    assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(marker_without_pause.last_command_at)

    string_at_marker = CommentSteering.put_command(marker, "status", "command-1", at: "2026-04-28T02:00:00Z")
    assert string_at_marker.last_command_at == "2026-04-28T02:00:00Z"

    fallback_at_marker = CommentSteering.put_command(marker, "status", "command-1", at: :not_a_datetime)
    assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(fallback_at_marker.last_command_at)

    body =
      """
      ## Symphony Status

      <!-- symphony:comments {"last_seen_comment_id":"comment-1","last_seen_comment_updated_at":"2026-04-28T01:00:00Z","paused":"true"} -->
      """

    assert {:ok, %{paused: true}} = CommentSteering.parse_marker(body)
  end

  test "does not replay acknowledged comments when Linear updates them after reactions" do
    {:ok, created_at, _offset} = DateTime.from_iso8601("2026-04-28T01:00:00Z")
    {:ok, reaction_updated_at, _offset} = DateTime.from_iso8601("2026-04-28T01:00:05Z")

    marker = %{
      last_seen_comment_id: "comment-1",
      last_seen_comment_updated_at: "2026-04-28T01:00:00Z"
    }

    reacted_comment = %Comment{
      id: "comment-1",
      body: "symphony status",
      created_at: created_at,
      updated_at: reaction_updated_at,
      author_id: "user-1",
      author_name: "Konark",
      author_is_bot: false
    }

    later_comment = comment("comment-2", "2026-04-28T01:00:01Z", "next real comment")

    assert CommentSteering.actionable_comments([reacted_comment, later_comment], {:ok, marker}) == [
             later_comment
           ]
  end

  test "formats steering and continuation context" do
    comments = [
      comment("comment-2", "2026-04-28T01:02:00Z", " second ", author_name: nil),
      comment("comment-1", "2026-04-28T01:01:00Z", "first", author_name: "Konark")
    ]

    assert CommentSteering.format_steering_message(comments) ==
             """
             New Linear comment context arrived. Treat it as actionable steering and adjust only if useful.

             - Konark: first
             - Human: second
             """
             |> String.trim()

    assert CommentSteering.continuation_context([List.first(comments), " direct ", 42]) ==
             "- Human: second\ndirect"

    assert CommentSteering.format_review_context(comments) ==
             "- comment_id=comment-1 parent_id=none author=Konark: first\n- comment_id=comment-2 parent_id=none author=Human: second"
  end

  test "handles comments with missing updated timestamps conservatively" do
    {:ok, created_at, _offset} = DateTime.from_iso8601("2026-04-28T01:00:00Z")

    created_only = %Comment{id: "created-only", body: "created", created_at: created_at}
    untimed = %Comment{id: "untimed", body: "untimed"}
    marker = %{last_seen_comment_id: "", last_seen_comment_updated_at: "2026-04-27T01:00:00Z"}

    assert CommentSteering.marker_for_comment(untimed) == %{
             last_seen_comment_id: "untimed",
             last_seen_comment_updated_at: nil,
             paused: false
           }

    assert CommentSteering.actionable_comments([untimed, created_only], {:ok, marker}) == [created_only]
    assert CommentSteering.latest_comment([untimed]) == untimed
  end

  test "falls back to updated timestamp and id ordering when needed" do
    {:ok, updated_at, _offset} = DateTime.from_iso8601("2026-04-28T01:01:00Z")

    updated_only = %Comment{
      id: "updated-only",
      body: "updated",
      updated_at: updated_at,
      author_id: "user-1",
      author_name: "Konark",
      author_is_bot: false
    }

    same_time_later_id = comment("comment-3", "2026-04-28T01:00:00Z", "same time later id")
    same_time_earlier_id = comment("comment-1", "2026-04-28T01:00:00Z", "same time earlier id")

    marker = %{last_seen_comment_id: "comment-2", last_seen_comment_updated_at: "2026-04-28T01:00:00Z"}

    comments = [updated_only, same_time_later_id, same_time_earlier_id]

    assert CommentSteering.actionable_comments(comments, {:ok, marker}) == [
             same_time_later_id,
             updated_only
           ]
  end

  defp comment(id, timestamp, body, opts \\ []) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(timestamp)

    %Comment{
      id: id,
      body: body,
      created_at: datetime,
      updated_at: Keyword.get(opts, :updated_at, datetime),
      author_id: Keyword.get(opts, :author_id, "user-1"),
      author_name: Keyword.get(opts, :author_name, "Konark"),
      author_is_bot: Keyword.get(opts, :bot?, false)
    }
  end
end
