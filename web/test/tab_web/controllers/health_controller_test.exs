defmodule TabWeb.HealthControllerTest do
  use TabWeb.ConnCase, async: true

  test "GET /healthz is ok when the database answers, with or without extraction", %{conn: conn} do
    body = conn |> get(~p"/healthz") |> json_response(200)

    assert body["status"] == "ok"
    assert body["db"] == "ok"
    assert body["version"] == "0.1.0"
    assert body["extract"] in ["ok", "unreachable"]
  end
end
