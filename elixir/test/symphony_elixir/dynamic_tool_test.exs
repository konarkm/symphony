defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises Linear dynamic tools" do
    specs = DynamicTool.tool_specs()

    assert %{
             "description" => description,
             "inputSchema" => %{
               "properties" => %{
                 "query" => _,
                 "variables" => _
               },
               "required" => ["query"],
               "type" => "object"
             },
             "name" => "linear_graphql"
           } = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert Enum.find(specs, &(&1["name"] == "linear_upload_file"))
    assert Enum.find(specs, &(&1["name"] == "linear_download_file"))

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "linear_upload_file", "linear_download_file"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  test "linear_upload_file validates workspace paths before calling Linear" do
    outside = Path.join(System.tmp_dir!(), "symphony-outside-upload.txt")
    File.write!(outside, "outside")

    workspace = Path.join(System.tmp_dir!(), "symphony-upload-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    response =
      DynamicTool.execute(
        "linear_upload_file",
        %{"path" => outside, "issueId" => "issue-1"},
        workspace: workspace,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for rejected paths")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "outside the issue workspace"
  after
    File.rm_rf(Path.join(System.tmp_dir!(), "symphony-outside-upload.txt"))
  end

  test "linear_upload_file rejects symlink escapes from the workspace" do
    workspace = Path.join(System.tmp_dir!(), "symphony-symlink-workspace-#{System.unique_integer([:positive])}")
    outside_dir = Path.join(System.tmp_dir!(), "symphony-symlink-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside_dir)
    outside_file = Path.join(outside_dir, "secret.txt")
    File.write!(outside_file, "secret")
    File.ln_s!(outside_dir, Path.join(workspace, "outside-link"))

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(outside_dir)
    end)

    response =
      DynamicTool.execute(
        "linear_upload_file",
        %{"path" => "outside-link/secret.txt", "issueId" => "issue-1"},
        workspace: workspace,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for symlink escapes")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "outside the issue workspace"
  end

  test "linear_upload_file uploads and attaches file to a threaded Linear reply" do
    workspace = Path.join(System.tmp_dir!(), "symphony-upload-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    file_path = Path.join(workspace, "artifact.txt")
    File.write!(file_path, "hello")
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_upload_file",
        %{
          "path" => "artifact.txt",
          "issueId" => "issue-1",
          "parentId" => "comment-1",
          "body" => "Attached artifact."
        },
        workspace: workspace,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          cond do
            query =~ "fileUpload" ->
              {:ok,
               %{
                 "data" => %{
                   "fileUpload" => %{
                     "success" => true,
                     "uploadFile" => %{
                       "uploadUrl" => "https://uploads.linear.test/artifact",
                       "assetUrl" => "https://assets.linear.test/artifact.txt",
                       "headers" => [%{"key" => "x-test", "value" => "1"}]
                     }
                   }
                 }
               }}

            query =~ "commentCreate" ->
              assert variables.parentId == "comment-1"
              assert variables.body =~ "Attached artifact."
              assert variables.body =~ "https://assets.linear.test/artifact.txt"
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "reply-1"}}}}}
          end
        end,
        upload_client: fn upload_url, uploaded_path, headers ->
          send(test_pid, {:upload_client_called, upload_url, uploaded_path, headers})
          :ok
        end
      )

    assert response["success"] == true
    assert_receive {:upload_client_called, "https://uploads.linear.test/artifact", ^file_path, headers}
    assert {"x-test", "1"} in headers
    assert {"content-type", "text/plain"} in headers
    assert Jason.decode!(response["output"])["assetUrl"] == "https://assets.linear.test/artifact.txt"
  end

  test "linear_download_file downloads accessible asset URLs into workspace" do
    workspace = Path.join(System.tmp_dir!(), "symphony-download-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    response =
      DynamicTool.execute(
        "linear_download_file",
        %{"url" => "https://assets.linear.test/demo.txt"},
        workspace: workspace,
        download_client: fn "https://assets.linear.test/demo.txt" ->
          {:ok, "asset body", [{"content-type", "text/plain"}]}
        end
      )

    assert response["success"] == true
    payload = Jason.decode!(response["output"])
    assert payload["path"] == Path.join([workspace, "linear-downloads", "demo.txt"])
    assert File.read!(payload["path"]) == "asset body"
  end
end
