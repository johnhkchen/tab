defmodule TabWeb.PageControllerTest do
  use TabWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Keeps the running tab for your house"
  end
end
