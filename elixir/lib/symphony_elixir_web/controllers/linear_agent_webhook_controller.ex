defmodule SymphonyElixirWeb.LinearAgentWebhookController do
  @moduledoc """
  Receives Linear AgentSession webhooks.
  """

  use Phoenix.Controller, formats: [:json]
  require Logger

  alias SymphonyElixir.{Config, Orchestrator, StateStore}
  alias SymphonyElixir.Linear.Agent

  @spec receive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive(conn, _params) do
    with :ok <- verify_signature(conn),
         :ok <- ensure_not_duplicate(conn),
         {:ok, event} <- Agent.normalize_webhook(conn.body_params) do
      Orchestrator.handle_agent_session_event(event)
      json(conn, %{ok: true})
    else
      {:duplicate, _delivery_id} ->
        json(conn, %{ok: true, duplicate: true})

      {:error, :invalid_signature} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid_signature"})

      {:error, reason} ->
        Logger.warning("Linear Agent webhook rejected: #{inspect(reason)}")
        conn |> put_status(:bad_request) |> json(%{ok: false, error: inspect(reason)})
    end
  end

  defp verify_signature(conn) do
    secret = Config.settings!().linear_agent.webhook_secret

    if is_nil(secret) or secret == "" do
      :ok
    else
      raw_body = conn.private[:raw_body] || ""
      expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
      actual = conn |> get_req_header("linear-signature") |> List.first()

      if secure_compare(expected, actual), do: :ok, else: {:error, :invalid_signature}
    end
  end

  defp ensure_not_duplicate(conn) do
    delivery_id =
      get_req_header(conn, "linear-delivery")
      |> List.first()

    cond do
      not is_binary(delivery_id) or delivery_id == "" ->
        :ok

      StateStore.seen_webhook?(delivery_id) ->
        {:duplicate, delivery_id}

      true ->
        StateStore.mark_webhook_seen(delivery_id)
        :ok
    end
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_compare(_left, _right), do: false
end
