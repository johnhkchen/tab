defmodule TabWeb.PaddleController do
  @moduledoc """
  Paddle's webhook (docs/specification.md, "Paddle webhook"). Answers 200
  only after the event is in the database, 401 for a bad signature, and 503
  when the database can't take it, so Paddle tries again. 404 off Hosted Tab.
  """
  use TabWeb, :controller

  require Logger

  alias Tab.Billing
  alias Tab.Billing.Paddle

  def webhook(conn, params) do
    secret = Application.get_env(:tab, :paddle, [])[:webhook_secret]
    signature = conn |> get_req_header("paddle-signature") |> List.first()

    cond do
      not Billing.cloud?() or secret in [nil, ""] ->
        send_resp(conn, 404, "")

      not Paddle.verify(TabWeb.RawBody.get(conn), signature, secret) ->
        send_resp(conn, 401, "")

      true ->
        try do
          case Paddle.handle(params) do
            {:ok, _} -> send_resp(conn, 200, "")
            {:error, :bad_event} -> send_resp(conn, 400, "")
          end
        rescue
          e ->
            Logger.error("Couldn't record a Paddle event: " <> Exception.message(e))
            send_resp(conn, 503, "")
        end
    end
  end
end
