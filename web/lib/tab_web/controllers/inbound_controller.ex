defmodule TabWeb.InboundController do
  @moduledoc """
  Resend's `email.received` webhook (docs/specification.md, "Forwarded email").
  Answers 200 only after the event is in the database, 401 for a bad
  signature, and 503 when the database can't take it, so Resend tries again.
  """
  use TabWeb, :controller

  require Logger

  alias Tab.Inbox
  alias Tab.Inbox.{Receiving, Resend}

  def resend(conn, params) do
    secret = Application.get_env(:tab, :resend_webhook_secret)
    headers = Map.new(conn.req_headers)

    cond do
      not Inbox.mail_enabled?() ->
        send_resp(conn, 404, "")

      not Resend.verify(TabWeb.RawBody.get(conn), headers, secret) ->
        send_resp(conn, 401, "")

      true ->
        accept(conn, params)
    end
  end

  defp accept(conn, %{"type" => "email.received", "data" => data}) do
    case data["email_id"] || data["id"] do
      id when is_binary(id) and id != "" ->
        try do
          {:ok, :ok} = Receiving.record(id)
          send_resp(conn, 200, "")
        rescue
          e ->
            Logger.error("Couldn't record received email: " <> Exception.message(e))
            send_resp(conn, 503, "")
        end

      _ ->
        send_resp(conn, 400, "")
    end
  end

  # Other events don't concern receiving; say thanks so Resend stops sending.
  defp accept(conn, _), do: send_resp(conn, 200, "")
end
