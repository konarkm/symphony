defmodule SymphonyElixir.LinearAgentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{Agent, OAuth}
  alias SymphonyElixir.StateStore

  test "OAuth install URL uses app actor and required scopes" do
    token_path = Path.join(System.tmp_dir!(), "linear-token-#{System.unique_integer([:positive])}.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      linear_agent_enabled: true,
      linear_agent_client_id: "client-123",
      linear_agent_client_secret: "secret-123",
      linear_agent_token_path: token_path,
      tracker_api_token: nil
    )

    File.mkdir_p!(Path.dirname(token_path))
    File.write!(token_path, Jason.encode!(%{"access_token" => "token"}))

    url = OAuth.authorize_url("state-123")
    assert url =~ "actor=app"
    assert url =~ "client_id=client-123"
    assert URI.decode_www_form(url) =~ "read write comments:create app:assignable app:mentionable"
    assert url =~ "state=state-123"
  end

  test "OAuth token store writes chmod 600 token file" do
    token_path = Path.join(System.tmp_dir!(), "linear-token-#{System.unique_integer([:positive])}.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      linear_agent_enabled: true,
      linear_agent_client_id: "client-123",
      linear_agent_client_secret: "secret-123",
      linear_agent_token_path: token_path,
      tracker_api_token: nil
    )

    assert :ok = OAuth.save_token(%{"access_token" => "token", "refresh_token" => "refresh"})
    assert {:ok, %{"access_token" => "token"}} = OAuth.load_token()
    assert {:ok, %File.Stat{mode: mode}} = File.stat(token_path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "OAuth detects expired and still-valid token lifetimes" do
    now = System.system_time(:second)

    refute OAuth.expired_or_expiring?(%{
             "access_token" => "token",
             "created_at" => now,
             "expires_in" => 86_400
           })

    assert OAuth.expired_or_expiring?(%{
             "access_token" => "token",
             "created_at" => now - 86_200,
             "expires_in" => 86_400
           })

    refute OAuth.expired_or_expiring?(%{"access_token" => "legacy-token"})
  end

  test "OAuth access token refresh path requires a refresh token when expired" do
    now = System.system_time(:second)

    assert {:error, :missing_linear_oauth_refresh_token} =
             OAuth.refresh_if_needed(%{
               "access_token" => "expired-token",
               "created_at" => now - 86_500,
               "expires_in" => 86_400
             })
  end

  test "AgentSession webhook normalizes created and prompted context" do
    payload = %{
      "action" => "prompted",
      "agentSession" => %{
        "id" => "session-1",
        "promptContext" => "<issue identifier=\"KM-1\"></issue>",
        "issue" => %{
          "id" => "issue-1",
          "identifier" => "KM-1",
          "title" => "Do work",
          "state" => %{"name" => "In Progress"},
          "labels" => %{"nodes" => [%{"name" => "Symphony"}]}
        }
      },
      "agentActivity" => %{"body" => "follow up"}
    }

    assert {:ok, event} = Agent.normalize_webhook(payload)
    assert event.action == "prompted"
    assert event.agent_session_id == "session-1"
    assert event.prompt_context =~ "KM-1"
    assert event.prompt_body == "follow up"
    assert event.issue.identifier == "KM-1"
    assert event.issue.labels == ["symphony"]
  end

  test "state store persists long-lived issue thread metadata" do
    state_path = Path.join(System.tmp_dir!(), "symphony-state-#{System.unique_integer([:positive])}.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      linear_agent_enabled: true,
      linear_agent_client_id: "client-123",
      linear_agent_client_secret: "secret-123",
      linear_agent_state_path: state_path,
      linear_agent_token_path: Path.join(System.tmp_dir!(), "linear-token.json"),
      tracker_api_token: nil
    )

    assert :ok = StateStore.put_issue("issue-1", %{thread_id: "thread-1", workspace_path: "/tmp/work"})
    assert %{"thread_id" => "thread-1", "workspace_path" => "/tmp/work"} = StateStore.get_issue("issue-1")
  end
end
