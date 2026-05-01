defmodule SymphonyElixirWeb.CacheBodyReader do
  @moduledoc false

  @spec read_body(Plug.Conn.t(), Keyword.t()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.put_private(conn, :raw_body, body)}
      {:more, body, conn} -> {:more, body, Plug.Conn.put_private(conn, :raw_body, body)}
      other -> other
    end
  end
end
