defmodule SymphonyElixir.Linear.OAuth do
  @moduledoc """
  Local OAuth helpers for Linear app-actor installation.
  """

  alias SymphonyElixir.Config

  @auth_url "https://linear.app/oauth/authorize"
  @token_url "https://api.linear.app/oauth/token"
  @required_scopes ["read", "write", "comments:create", "app:assignable", "app:mentionable"]

  @type token :: %{optional(String.t()) => term()}

  @spec required_scopes() :: [String.t()]
  def required_scopes, do: @required_scopes

  @spec authorize_url(String.t()) :: String.t()
  def authorize_url(state) when is_binary(state) do
    settings = Config.settings!().linear_agent

    query =
      URI.encode_query(%{
        "client_id" => settings.client_id || "",
        "redirect_uri" => settings.redirect_uri,
        "response_type" => "code",
        "scope" => Enum.join(@required_scopes, " "),
        "actor" => "app",
        "state" => state
      })

    @auth_url <> "?" <> query
  end

  @spec exchange_code(String.t()) :: {:ok, token()} | {:error, term()}
  def exchange_code(code) when is_binary(code) do
    settings = Config.settings!().linear_agent

    Req.post(@token_url,
      form: [
        grant_type: "authorization_code",
        code: code,
        redirect_uri: settings.redirect_uri,
        client_id: settings.client_id,
        client_secret: settings.client_secret
      ],
      connect_options: [timeout: 30_000]
    )
    |> normalize_token_response()
  end

  @spec load_token() :: {:ok, token()} | {:error, term()}
  def load_token do
    token_path = Config.settings!().linear_agent.token_path
    load_token(token_path)
  end

  @spec load_token(String.t()) :: {:ok, token()} | {:error, term()}
  def load_token(token_path) when is_binary(token_path) do
    with {:ok, body} <- File.read(token_path),
         {:ok, token} when is_map(token) <- Jason.decode(body),
         access_token when is_binary(access_token) <- Map.get(token, "access_token") do
      {:ok, token}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_linear_oauth_token}
    end
  end

  @spec save_token(token()) :: :ok | {:error, term()}
  def save_token(token) when is_map(token) do
    token_path = Config.settings!().linear_agent.token_path
    token_body = Jason.encode_to_iodata!(Map.put_new(token, "created_at", System.system_time(:second)))

    case File.mkdir_p(Path.dirname(token_path)) do
      :ok ->
        write_token(token_path, token_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec access_token() :: {:ok, String.t()} | {:error, term()}
  def access_token do
    with {:ok, token} <- load_token(),
         access_token when is_binary(access_token) <- Map.get(token, "access_token") do
      {:ok, access_token}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_linear_oauth_access_token}
    end
  end

  defp normalize_token_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    case body do
      %{} = token -> {:ok, token}
      _ -> {:error, :invalid_oauth_token_response}
    end
  end

  defp normalize_token_response({:ok, %{status: status, body: body}}), do: {:error, {:oauth_status, status, body}}
  defp normalize_token_response({:error, reason}), do: {:error, reason}

  defp write_token(token_path, token_body) do
    case File.write(token_path, token_body) do
      :ok -> File.chmod(token_path, 0o600)
      {:error, reason} -> {:error, reason}
    end
  end
end
