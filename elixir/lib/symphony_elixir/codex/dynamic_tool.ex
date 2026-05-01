defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, PathSafety, RepoResolver, Tracker}
  alias SymphonyElixir.Linear.{Agent, Client}

  @linear_graphql_tool "linear_graphql"
  @linear_upload_file_tool "linear_upload_file"
  @linear_download_file_tool "linear_download_file"
  @linear_agent_activity_tool "linear_agent_activity"
  @linear_agent_update_session_tool "linear_agent_update_session"
  @linear_update_issue_state_tool "linear_update_issue_state"
  @symphony_repo_inventory_tool "symphony_repo_inventory"
  @max_upload_bytes 50 * 1_024 * 1_024
  @max_download_bytes 50 * 1_024 * 1_024
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  Use this only for non-routine Linear operations; Symphony's outer runtime manages issue pickup,
  status comments, comment markers, and eyes reactions. Do not query User.isBot or Issue.links,
  because this Linear workspace schema does not expose those fields.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @linear_upload_file_description """
  Upload an existing local file from the issue workspace to Linear, then attach its asset URL to a Linear comment.
  Prefer this for generated artifacts, screenshots, videos, images, and logs instead of pasting long content.
  By default, paths must stay inside the current issue workspace.
  """
  @linear_upload_file_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["path"],
    "properties" => %{
      "path" => %{"type" => "string", "description" => "Local file path, absolute or relative to the issue workspace."},
      "issueId" => %{"type" => ["string", "null"], "description" => "Linear issue id. Defaults to the active issue."},
      "parentId" => %{"type" => ["string", "null"], "description" => "Optional parent comment id for a threaded reply."},
      "commentId" => %{"type" => ["string", "null"], "description" => "Optional existing comment id to update instead of creating a comment."},
      "body" => %{"type" => ["string", "null"], "description" => "Comment body. The Linear asset URL is appended automatically."},
      "allowOutsideWorkspace" => %{"type" => "boolean", "description" => "Allow absolute paths outside the issue workspace. Defaults to false."}
    }
  }
  @linear_download_file_description """
  Download a Linear-accessible asset URL into the current issue workspace.
  Use this when a Linear comment includes a file URL that the agent needs to inspect locally.
  """
  @linear_download_file_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["url"],
    "properties" => %{
      "url" => %{"type" => "string", "description" => "HTTP(S) Linear asset URL to download."},
      "path" => %{"type" => ["string", "null"], "description" => "Destination file path, absolute or relative to the issue workspace."},
      "allowOutsideWorkspace" => %{"type" => "boolean", "description" => "Allow destination paths outside the issue workspace. Defaults to false."}
    }
  }
  @linear_agent_activity_description """
  Emit a native Linear Agent Activity in the current AgentSession. Use this for sparse coworker updates,
  elicitation, final responses, meaningful actions, and errors.

  Content must use Linear Agent Activity types:
  - `response` with `body` for direct answers and final responses.
  - `thought` with `body` for sparse progress updates.
  - `elicitation` with `body` for clarifying questions.
  - `error` with `body` for blockers/failures.
  - `action` with `action`, `parameter`, and optional `result` for tool-like activity.
  """
  @linear_agent_activity_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["content"],
    "properties" => %{
      "agentSessionId" => %{"type" => ["string", "null"], "description" => "Linear AgentSession id. Defaults to current session."},
      "content" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["type"],
        "properties" => %{
          "type" => %{
            "type" => "string",
            "enum" => ["thought", "response", "elicitation", "error", "action"],
            "description" => "Use response for direct answers/final replies, thought for progress, elicitation for questions, error for blockers, and action for tool-like actions."
          },
          "body" => %{"type" => "string", "description" => "Required for thought, response, elicitation, and error."},
          "action" => %{"type" => "string", "description" => "Required for action activities."},
          "parameter" => %{"type" => "string", "description" => "Required for action activities."},
          "result" => %{"type" => ["string", "null"], "description" => "Optional result for action activities."}
        }
      }
    }
  }
  @linear_agent_update_session_description """
  Update native Linear AgentSession metadata such as plan and externalUrls. Plan updates replace the full plan.
  """
  @linear_agent_update_session_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["input"],
    "properties" => %{
      "agentSessionId" => %{"type" => ["string", "null"], "description" => "Linear AgentSession id. Defaults to current session."},
      "input" => %{"type" => "object", "additionalProperties" => true}
    }
  }
  @linear_update_issue_state_description """
  Move the active Linear issue to a named workflow state. Use this for semantic coworker state
  transitions such as Blocked, Human Review, Rework, Done, and Canceled. Merging still only
  happens when the issue is already in the Merging state.
  """
  @linear_update_issue_state_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["state"],
    "properties" => %{
      "issueId" => %{"type" => ["string", "null"], "description" => "Linear issue id. Defaults to the active issue."},
      "state" => %{"type" => "string", "description" => "Target Linear workflow state name, for example Human Review or Blocked."}
    }
  }
  @symphony_repo_inventory_description """
  List repositories under Symphony's explicitly configured local repo roots. Use this before deciding
  which repo to clone or asking the user for clarification.
  """
  @symphony_repo_inventory_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "query" => %{"type" => ["string", "null"], "description" => "Optional repo name/path/remote search text."}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @linear_upload_file_tool ->
        execute_linear_upload_file(arguments, opts)

      @linear_download_file_tool ->
        execute_linear_download_file(arguments, opts)

      @linear_agent_activity_tool ->
        execute_linear_agent_activity(arguments, opts)

      @linear_agent_update_session_tool ->
        execute_linear_agent_update_session(arguments, opts)

      @linear_update_issue_state_tool ->
        execute_linear_update_issue_state(arguments, opts)

      @symphony_repo_inventory_tool ->
        execute_symphony_repo_inventory(arguments)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @linear_upload_file_tool,
        "description" => @linear_upload_file_description,
        "inputSchema" => @linear_upload_file_input_schema
      },
      %{
        "name" => @linear_download_file_tool,
        "description" => @linear_download_file_description,
        "inputSchema" => @linear_download_file_input_schema
      },
      %{
        "name" => @linear_agent_activity_tool,
        "description" => @linear_agent_activity_description,
        "inputSchema" => @linear_agent_activity_input_schema
      },
      %{
        "name" => @linear_agent_update_session_tool,
        "description" => @linear_agent_update_session_description,
        "inputSchema" => @linear_agent_update_session_input_schema
      },
      %{
        "name" => @linear_update_issue_state_tool,
        "description" => @linear_update_issue_state_description,
        "inputSchema" => @linear_update_issue_state_input_schema
      },
      %{
        "name" => @symphony_repo_inventory_tool,
        "description" => @symphony_repo_inventory_description,
        "inputSchema" => @symphony_repo_inventory_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_upload_file(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    upload_client = Keyword.get(opts, :upload_client, &default_upload_client/3)

    with {:ok, input} <- normalize_map_arguments(arguments, @linear_upload_file_tool),
         :ok <- ensure_local_file_tool(opts),
         {:ok, workspace} <- workspace_from_opts(opts),
         {:ok, file_path} <- resolve_file_path(input, workspace),
         :ok <- validate_upload_path(file_path, workspace, truthy?(Map.get(input, "allowOutsideWorkspace"))),
         {:ok, file_info} <- upload_file_info(file_path),
         {:ok, issue_id} <- issue_id_for_upload(input, opts),
         {:ok, upload_payload} <- request_linear_upload(linear_client, file_info),
         :ok <- upload_to_asset(upload_client, upload_payload, file_path, file_info),
         {:ok, comment_payload} <- attach_asset_to_comment(linear_client, input, issue_id, upload_payload) do
      dynamic_tool_response(
        true,
        encode_payload(%{
          "assetUrl" => upload_payload.asset_url,
          "file" => file_info.public,
          "comment" => comment_payload
        })
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_download_file(arguments, opts) do
    download_client = Keyword.get(opts, :download_client, &default_download_client/1)

    with {:ok, input} <- normalize_map_arguments(arguments, @linear_download_file_tool),
         :ok <- ensure_local_file_tool(opts),
         {:ok, workspace} <- workspace_from_opts(opts),
         {:ok, url} <- normalize_required_string(input, "url"),
         :ok <- validate_http_url(url),
         {:ok, destination} <- resolve_download_path(input, workspace, url),
         :ok <- validate_download_path(destination, workspace, truthy?(Map.get(input, "allowOutsideWorkspace"))),
         {:ok, body, headers} <- download_client.(url),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.write(destination, body) do
      dynamic_tool_response(
        true,
        encode_payload(%{
          "path" => destination,
          "bytes" => byte_size(body),
          "headers" => response_headers_payload(headers)
        })
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_agent_activity(arguments, opts) do
    with {:ok, input} <- normalize_map_arguments(arguments, @linear_agent_activity_tool),
         {:ok, agent_session_id} <- agent_session_id(input, opts),
         {:ok, content} <- normalize_content_map(input) do
      case Agent.create_activity(agent_session_id, content) do
        :ok -> dynamic_tool_response(true, encode_payload(%{"ok" => true}))
        {:error, reason} -> failure_response(tool_error_payload(reason))
      end
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_agent_update_session(arguments, opts) do
    with {:ok, input} <- normalize_map_arguments(arguments, @linear_agent_update_session_tool),
         {:ok, agent_session_id} <- agent_session_id(input, opts),
         {:ok, session_input} <- normalize_session_input(input) do
      case Agent.update_session(agent_session_id, session_input) do
        :ok -> dynamic_tool_response(true, encode_payload(%{"ok" => true}))
        {:error, reason} -> failure_response(tool_error_payload(reason))
      end
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_update_issue_state(arguments, opts) do
    with {:ok, input} <- normalize_map_arguments(arguments, @linear_update_issue_state_tool),
         {:ok, issue_id} <- issue_id_for_tool(input, opts),
         {:ok, state_name} <- normalize_required_string(input, "state") do
      case Tracker.update_issue_state(issue_id, state_name) do
        :ok -> dynamic_tool_response(true, encode_payload(%{"ok" => true, "issueId" => issue_id, "state" => state_name}))
        {:error, reason} -> failure_response(tool_error_payload(reason))
      end
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_symphony_repo_inventory(arguments) do
    query =
      case arguments do
        %{"query" => query} when is_binary(query) -> String.trim(query)
        _ -> ""
      end

    repos =
      if query == "" do
        RepoResolver.local_repositories()
      else
        case RepoResolver.find_local(query) do
          {:ok, repo} -> [repo]
          {:ambiguous, repos} -> repos
          :not_found -> []
        end
      end

    dynamic_tool_response(true, encode_payload(%{"roots" => RepoResolver.configured_roots(), "repositories" => repos}))
  end

  defp agent_session_id(input, opts) do
    case Map.get(input, "agentSessionId") || Keyword.get(opts, :agent_session_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_agent_session_id}
    end
  end

  defp normalize_content_map(%{"content" => %{"type" => "update"} = content}) do
    {:ok, Map.put(content, "type", "response")}
  end

  defp normalize_content_map(%{"content" => content}) when is_map(content), do: {:ok, content}
  defp normalize_content_map(_input), do: {:error, :missing_agent_activity_content}

  defp normalize_session_input(%{"input" => input}) when is_map(input), do: {:ok, input}
  defp normalize_session_input(_input), do: {:error, :missing_agent_session_input}

  @file_upload_mutation """
  mutation SymphonyFileUpload($contentType: String!, $filename: String!, $size: Int!) {
    fileUpload(contentType: $contentType, filename: $filename, size: $size) {
      success
      uploadFile {
        uploadUrl
        assetUrl
        headers {
          key
          value
        }
      }
    }
  }
  """

  @create_comment_with_asset_mutation """
  mutation SymphonyCreateAttachmentComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        body
      }
    }
  }
  """

  @create_reply_with_asset_mutation """
  mutation SymphonyCreateAttachmentReply($issueId: String!, $parentId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, parentId: $parentId, body: $body}) {
      success
      comment {
        id
        body
      }
    }
  }
  """

  @update_comment_with_asset_mutation """
  mutation SymphonyUpdateAttachmentComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment {
        id
        body
      }
    }
  }
  """

  defp normalize_map_arguments(arguments, _tool) when is_map(arguments), do: {:ok, stringify_keys(arguments)}
  defp normalize_map_arguments(_arguments, tool), do: {:error, {:invalid_tool_arguments, tool}}

  defp ensure_local_file_tool(opts) do
    case Keyword.get(opts, :worker_host) do
      nil -> :ok
      "" -> :ok
      worker_host when is_binary(worker_host) -> {:error, {:remote_file_tool_unsupported, worker_host}}
      _ -> :ok
    end
  end

  defp workspace_from_opts(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" -> {:ok, Path.expand(workspace)}
      _ -> {:error, :missing_workspace}
    end
  end

  defp resolve_file_path(input, workspace) do
    with {:ok, path} <- normalize_required_string(input, "path") do
      {:ok, expand_relative(path, workspace)}
    end
  end

  defp validate_upload_path(path, workspace, allow_outside_workspace) do
    with {:ok, canonical_path} <- canonicalize_existing(path),
         {:ok, canonical_workspace} <- canonicalize_existing(workspace),
         :ok <- ensure_regular_file(canonical_path) do
      ensure_inside_workspace(canonical_path, canonical_workspace, allow_outside_workspace)
    end
  end

  defp upload_file_info(path) do
    case File.stat(path) do
      {:ok, stat} ->
        with :ok <- validate_upload_size(stat.size) do
          content_type = MIME.from_path(path)

          {:ok,
           %{
             path: path,
             filename: Path.basename(path),
             size: stat.size,
             content_type: content_type,
             public: %{
               "path" => path,
               "filename" => Path.basename(path),
               "size" => stat.size,
               "contentType" => content_type
             }
           }}
        end

      {:error, reason} ->
        {:error, {:file_stat_failed, path, reason}}
    end
  end

  defp validate_upload_size(size) when is_integer(size) and size > 0 and size <= @max_upload_bytes, do: :ok
  defp validate_upload_size(0), do: {:error, :empty_file}
  defp validate_upload_size(size) when is_integer(size) and size > @max_upload_bytes, do: {:error, {:file_too_large, size, @max_upload_bytes}}
  defp validate_upload_size(size), do: {:error, {:invalid_file_size, size}}

  defp issue_id_for_upload(input, opts) do
    issue_id_for_tool(input, opts, :missing_issue_id)
  end

  defp issue_id_for_tool(input, opts, missing_reason \\ :missing_active_issue_id) do
    case Map.get(input, "issueId") do
      issue_id when is_binary(issue_id) and issue_id != "" ->
        {:ok, issue_id}

      _ ->
        case Keyword.get(opts, :issue) do
          %{id: issue_id} when is_binary(issue_id) and issue_id != "" -> {:ok, issue_id}
          _ -> {:error, missing_reason}
        end
    end
  end

  defp request_linear_upload(linear_client, file_info) do
    variables = %{
      contentType: file_info.content_type,
      filename: file_info.filename,
      size: file_info.size
    }

    with {:ok, response} <- linear_client.(@file_upload_mutation, variables, []),
         true <- get_in(response, ["data", "fileUpload", "success"]) == true,
         upload_file when is_map(upload_file) <- get_in(response, ["data", "fileUpload", "uploadFile"]),
         upload_url when is_binary(upload_url) <- Map.get(upload_file, "uploadUrl"),
         asset_url when is_binary(asset_url) <- Map.get(upload_file, "assetUrl") do
      {:ok,
       %{
         upload_url: upload_url,
         asset_url: asset_url,
         headers: normalize_upload_headers(Map.get(upload_file, "headers"))
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :linear_file_upload_failed}
    end
  end

  defp upload_to_asset(upload_client, upload_payload, file_path, file_info) do
    headers =
      upload_payload.headers
      |> List.keystore("content-type", 0, {"content-type", file_info.content_type})

    upload_client.(upload_payload.upload_url, file_path, headers)
  end

  defp attach_asset_to_comment(linear_client, input, issue_id, upload_payload) do
    body = upload_comment_body(Map.get(input, "body"), upload_payload.asset_url)

    cond do
      comment_id = nonblank_string(Map.get(input, "commentId")) ->
        graphql_comment_mutation(
          linear_client,
          @update_comment_with_asset_mutation,
          %{commentId: comment_id, body: body},
          "commentUpdate"
        )

      parent_id = nonblank_string(Map.get(input, "parentId")) ->
        graphql_comment_mutation(
          linear_client,
          @create_reply_with_asset_mutation,
          %{issueId: issue_id, parentId: parent_id, body: body},
          "commentCreate"
        )

      true ->
        graphql_comment_mutation(
          linear_client,
          @create_comment_with_asset_mutation,
          %{issueId: issue_id, body: body},
          "commentCreate"
        )
    end
  end

  defp graphql_comment_mutation(linear_client, query, variables, operation) do
    with {:ok, response} <- linear_client.(query, variables, []),
         true <- get_in(response, ["data", operation, "success"]) == true do
      {:ok, get_in(response, ["data", operation, "comment"]) || %{}}
    else
      false -> {:error, {:linear_comment_attach_failed, operation}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:linear_comment_attach_failed, operation}}
    end
  end

  defp upload_comment_body(body, asset_url) do
    body =
      case body do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    if body == "" do
      asset_url
    else
      body <> "\n\n" <> asset_url
    end
  end

  defp resolve_download_path(input, workspace, url) do
    destination =
      case Map.get(input, "path") do
        path when is_binary(path) ->
          case String.trim(path) do
            "" -> Path.join([workspace, "linear-downloads", url_basename(url)])
            trimmed -> expand_relative(trimmed, workspace)
          end

        _ ->
          Path.join([workspace, "linear-downloads", url_basename(url)])
      end

    {:ok, destination}
  end

  defp validate_download_path(path, workspace, allow_outside_workspace) do
    with {:ok, canonical_parent} <- canonicalize_or_create_parent(path),
         {:ok, canonical_workspace} <- canonicalize_existing(workspace) do
      ensure_inside_workspace(canonical_parent, canonical_workspace, allow_outside_workspace)
    end
  end

  defp default_upload_client(upload_url, file_path, headers) do
    with {:ok, body} <- File.read(file_path),
         {:ok, %Req.Response{status: status}} when status in 200..299 <-
           Req.put(upload_url, body: body, headers: headers) do
      :ok
    else
      {:ok, %Req.Response{status: status}} -> {:error, {:linear_asset_upload_status, status}}
      {:error, reason} -> {:error, {:linear_asset_upload_failed, reason}}
    end
  end

  defp default_download_client(url) do
    headers = linear_asset_auth_headers(url)

    case Req.get(url, headers: headers, decode_body: false) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} when status in 200..299 and is_binary(body) ->
        with :ok <- validate_download_size(byte_size(body)) do
          {:ok, body, headers}
        end

      {:ok, %Req.Response{status: status, body: body, headers: headers}} when status in 200..299 ->
        body = IO.iodata_to_binary(body)

        with :ok <- validate_download_size(byte_size(body)) do
          {:ok, body, headers}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:linear_asset_download_status, status}}

      {:error, reason} ->
        {:error, {:linear_asset_download_failed, reason}}
    end
  end

  defp linear_asset_auth_headers(url) do
    host = URI.parse(url).host || ""

    if String.ends_with?(host, "linear.app") or String.ends_with?(host, "linearusercontent.com") do
      case Config.settings!().tracker.api_key do
        token when is_binary(token) -> [{"authorization", token}]
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp validate_download_size(size) when is_integer(size) and size <= @max_download_bytes, do: :ok
  defp validate_download_size(size) when is_integer(size), do: {:error, {:download_too_large, size, @max_download_bytes}}

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:invalid_tool_arguments, tool}) do
    %{
      "error" => %{
        "message" => "`#{tool}` expects a JSON object argument."
      }
    }
  end

  defp tool_error_payload(:missing_workspace) do
    %{
      "error" => %{
        "message" => "This tool requires the active issue workspace."
      }
    }
  end

  defp tool_error_payload({:remote_file_tool_unsupported, worker_host}) do
    %{
      "error" => %{
        "message" => "Linear file tools are disabled for SSH worker sessions because the file lives on the remote worker filesystem.",
        "workerHost" => worker_host
      }
    }
  end

  defp tool_error_payload(:missing_issue_id) do
    %{
      "error" => %{
        "message" => "`linear_upload_file` requires `issueId` when there is no active issue context."
      }
    }
  end

  defp tool_error_payload(:missing_active_issue_id) do
    %{
      "error" => %{
        "message" => "`linear_update_issue_state` requires `issueId` when there is no active issue context."
      }
    }
  end

  defp tool_error_payload({:missing_required_argument, name}) do
    %{
      "error" => %{
        "message" => "Missing required argument `#{name}`."
      }
    }
  end

  defp tool_error_payload({:path_canonicalize_failed, path, reason}) do
    %{
      "error" => %{
        "message" => "Could not resolve file path.",
        "path" => path,
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:not_a_regular_file, path}) do
    %{
      "error" => %{
        "message" => "`linear_upload_file` can only upload regular files.",
        "path" => path
      }
    }
  end

  defp tool_error_payload({:outside_workspace, path, workspace}) do
    %{
      "error" => %{
        "message" => "Path is outside the issue workspace. Pass `allowOutsideWorkspace: true` only when that is intentional.",
        "path" => path,
        "workspace" => workspace
      }
    }
  end

  defp tool_error_payload(:empty_file) do
    %{
      "error" => %{
        "message" => "`linear_upload_file` rejected an empty file."
      }
    }
  end

  defp tool_error_payload({:file_too_large, size, limit}) do
    %{
      "error" => %{
        "message" => "`linear_upload_file` rejected a file larger than the configured safety limit.",
        "size" => size,
        "limit" => limit
      }
    }
  end

  defp tool_error_payload({:download_too_large, size, limit}) do
    %{
      "error" => %{
        "message" => "`linear_download_file` rejected a response larger than the configured safety limit.",
        "size" => size,
        "limit" => limit
      }
    }
  end

  defp tool_error_payload({:file_stat_failed, path, reason}) do
    %{
      "error" => %{
        "message" => "Could not inspect file for upload.",
        "path" => path,
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:linear_file_upload_failed) do
    %{
      "error" => %{
        "message" => "Linear did not return a usable file upload target."
      }
    }
  end

  defp tool_error_payload({:linear_comment_attach_failed, operation}) do
    %{
      "error" => %{
        "message" => "Linear file upload succeeded, but attaching the asset URL to a comment failed.",
        "operation" => operation
      }
    }
  end

  defp tool_error_payload(:invalid_url) do
    %{
      "error" => %{
        "message" => "`linear_download_file.url` must be an HTTP(S) URL."
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_required_argument, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_required_argument, key}}
    end
  end

  defp nonblank_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank_string(_value), do: nil

  defp expand_relative(path, workspace) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, workspace)
    end
  end

  defp canonicalize_existing(path) do
    expanded = path |> Path.expand() |> Path.absname()

    with true <- File.exists?(expanded),
         {:ok, canonical} <- PathSafety.canonicalize(expanded) do
      {:ok, canonical}
    else
      false -> {:error, {:path_canonicalize_failed, path, :enoent}}
      {:error, {:path_canonicalize_failed, _path, reason}} -> {:error, {:path_canonicalize_failed, path, reason}}
    end
  end

  defp canonicalize_or_create_parent(path) do
    parent = Path.dirname(path)

    with :ok <- File.mkdir_p(parent) do
      canonicalize_existing(parent)
    end
  end

  defp ensure_regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, {:not_a_regular_file, path}}
      {:error, reason} -> {:error, {:file_stat_failed, path, reason}}
    end
  end

  defp ensure_inside_workspace(_path, _workspace, true), do: :ok

  defp ensure_inside_workspace(path, workspace, false) do
    workspace_prefix = workspace <> "/"

    if path == workspace or String.starts_with?(path, workspace_prefix) do
      :ok
    else
      {:error, {:outside_workspace, path, workspace}}
    end
  end

  defp normalize_upload_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) -> [{String.downcase(key), value}]
      %{"name" => key, "value" => value} when is_binary(key) and is_binary(value) -> [{String.downcase(key), value}]
      {key, value} when is_binary(key) and is_binary(value) -> [{String.downcase(key), value}]
      _ -> []
    end)
  end

  defp normalize_upload_headers(_headers), do: []

  defp response_headers_payload(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} when is_binary(key) and is_binary(value) -> [%{"key" => key, "value" => value}]
      %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) -> [%{"key" => key, "value" => value}]
      _ -> []
    end)
  end

  defp response_headers_payload(_headers), do: []

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp validate_http_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> :ok
      _ -> {:error, :invalid_url}
    end
  end

  defp url_basename(url) do
    path =
      url
      |> URI.parse()
      |> Map.get(:path)
      |> to_string()

    case Path.basename(path) do
      "" -> "linear-asset"
      "/" -> "linear-asset"
      basename -> basename
    end
  end
end
