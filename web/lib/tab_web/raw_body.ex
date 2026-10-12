defmodule TabWeb.RawBody do
  @moduledoc """
  Keeps the exact request body for webhooks under `/inbound/`, whose
  signatures cover the bytes as sent, not the parsed JSON. Other requests are
  read as usual.
  """

  def read_body(%Plug.Conn{request_path: "/inbound/" <> _} = conn, opts) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn, opts) do
      {:ok, body, Plug.Conn.assign(conn, :raw_body, [body | conn.assigns[:raw_body] || []])}
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  @doc "The body as it arrived."
  def get(conn),
    do: conn.assigns[:raw_body] |> List.wrap() |> Enum.reverse() |> IO.iodata_to_binary()
end
