defmodule SymphonyElixirWeb.LinearOAuthController do
  @moduledoc """
  Minimal local OAuth callback for Linear app-actor installs.
  """

  use Phoenix.Controller, formats: [:html, :json]

  alias SymphonyElixir.Linear.OAuth

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"code" => code}) do
    case OAuth.exchange_code(code) do
      {:ok, token} ->
        :ok = OAuth.save_token(token)
        text(conn, "Symphony Linear OAuth install complete. You can close this tab.")

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> text("Symphony Linear OAuth install failed: #{inspect(reason)}")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> text("Missing Linear OAuth code.")
  end
end
