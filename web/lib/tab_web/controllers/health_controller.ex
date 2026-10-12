defmodule TabWeb.HealthController do
  use TabWeb, :controller

  @doc """
  Liveness for Docker and uptime checks. The database must answer; the
  extraction service is reported but optional, because nothing in Tab's ledger
  depends on AI (spec §9).
  """
  def show(conn, _params) do
    db = check_db()

    conn
    |> put_status(if db == "ok", do: 200, else: 503)
    |> json(%{
      status: if(db == "ok", do: "ok", else: "degraded"),
      version: Application.spec(:tab, :vsn) |> to_string(),
      db: db,
      extract: check_extract()
    })
  end

  defp check_db do
    case Tab.Repo.query("SELECT 1") do
      {:ok, _} -> "ok"
      {:error, _} -> "unreachable"
    end
  end

  defp check_extract do
    url = Application.fetch_env!(:tab, :extract_url) <> "/health"

    case Req.get(url, retry: false, receive_timeout: 1_000, connect_options: [timeout: 1_000]) do
      {:ok, %{status: 200}} -> "ok"
      _ -> "unreachable"
    end
  end
end
