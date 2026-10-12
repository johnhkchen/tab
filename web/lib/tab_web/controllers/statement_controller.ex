defmodule TabWeb.StatementController do
  @moduledoc """
  `/s/:token`: one person's month, readable without signing in
  (`Tab.Statements.read/1`). A link that doesn't work gets the same 404,
  whatever the reason. The token is in the URL, so the page is never cached,
  indexed, or sent on as a referrer.
  """
  use TabWeb, :controller

  def show(conn, %{"token" => token}) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")

    case Tab.Statements.read(token) do
      {:ok, statement} ->
        render(conn, :show, s: statement, page_title: "Statement")

      {:error, _} ->
        conn |> put_status(:not_found) |> render(:gone, page_title: "Statement")
    end
  end
end
