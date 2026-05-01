defmodule SymphonyElixir.StateStore do
  @moduledoc """
  Small local JSON state store for durable issue rooms.
  """

  alias SymphonyElixir.Config

  @empty %{"issues" => %{}, "webhooks" => %{}}

  @spec get_issue(String.t()) :: map()
  def get_issue(issue_id) when is_binary(issue_id) do
    load()
    |> get_in(["issues", issue_id])
    |> case do
      %{} = issue -> issue
      _ -> %{}
    end
  end

  @spec put_issue(String.t(), map()) :: :ok | {:error, term()}
  def put_issue(issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    update(fn state ->
      put_in(state, ["issues", issue_id], Map.merge(get_in(state, ["issues", issue_id]) || %{}, stringify_keys(attrs)))
    end)
  end

  @spec seen_webhook?(String.t()) :: boolean()
  def seen_webhook?(delivery_id) when is_binary(delivery_id) do
    Map.has_key?(load()["webhooks"] || %{}, delivery_id)
  end

  @spec mark_webhook_seen(String.t()) :: :ok | {:error, term()}
  def mark_webhook_seen(delivery_id) when is_binary(delivery_id) do
    update(fn state ->
      put_in(state, ["webhooks", delivery_id], DateTime.to_iso8601(DateTime.utc_now()))
    end)
  end

  @spec load() :: map()
  def load do
    path = state_path()

    with {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      Map.merge(@empty, decoded)
    else
      _ -> @empty
    end
  end

  @spec update((map() -> map())) :: :ok | {:error, term()}
  def update(fun) when is_function(fun, 1) do
    path = state_path()
    state = fun.(load())

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        write_state_file(path, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp state_path, do: Config.settings!().linear_agent.state_path

  defp write_state_file(path, state) do
    case File.write(path, Jason.encode_to_iodata!(state)) do
      :ok -> File.chmod(path, 0o600)
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
