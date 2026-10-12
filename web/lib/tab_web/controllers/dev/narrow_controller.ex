defmodule TabWeb.Dev.NarrowController do
  @moduledoc """
  Development only (routed under /dev, which exists only with `dev_routes`).
  Signs in as a seeded demo person and shows every page in a 360 px frame,
  then reports any page that scrolls sideways. `mise run check:narrow` reads
  the report with headless Chrome; open it yourself to look at the pages.
  """
  use TabWeb, :controller

  alias Tab.{Accounts, Groups, Ledger}

  @width 360

  def show(conn, params) do
    email = params["email"] || "priya@example.com"

    user =
      Accounts.get_user_by_email(email) ||
        raise "run the seeds first: mix run priv/repo/seeds.exs"

    scope = Accounts.Scope.for_user(user)
    token = Accounts.generate_user_session_token(user)

    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> html(page(paths(scope), params["shots"] == "1"))
  end

  defp paths(scope) do
    {:ok, [group | _]} = Groups.list_groups(scope)
    {:ok, expenses} = Ledger.list_expenses(scope, group.id)
    expense = List.first(expenses)

    [
      ~p"/groups",
      ~p"/groups/#{group}",
      ~p"/groups/#{group}/expenses/new",
      expense && ~p"/groups/#{group}/expenses/#{expense}",
      expense && ~p"/groups/#{group}/expenses/#{expense}/edit",
      ~p"/groups/#{group}/settle",
      ~p"/groups/#{group}/members",
      ~p"/profile",
      ~p"/users/settings",
      ~p"/welcome",
      ~p"/join/not-a-real-token",
      ~p"/users/log-in"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp page(paths, shots?) do
    frames =
      Enum.map_join(paths, "\n", fn path ->
        ~s(<figure><figcaption>#{path}</figcaption><iframe sandbox="allow-same-origin" src="#{path}" width="#{@width}" height="#{if shots?, do: 760, else: 400}"></iframe></figure>)
      end)

    """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Tab at #{@width} px</title>
    <style>
      body { margin: 16px; font: 13px system-ui; background: #ddd; }
      #frames { display: flex; flex-wrap: wrap; gap: 16px; }
      figure { margin: 0; } iframe { border: 1px solid #999; background: white; }
      figcaption { margin-bottom: 4px; }
    </style></head>
    <body>
    <pre id="report">checking…</pre>
    <div id="frames">#{frames}</div>
    <script>
      // Frames are sandboxed without scripts: the server-rendered page is the
      // whole layout, and no live connections keep headless Chrome waiting.
      addEventListener("load", () => {
        const lines = [...document.querySelectorAll("iframe[sandbox]")].map(f => {
          const doc = f.contentDocument
          const wide = doc.documentElement.scrollWidth
          const culprits = [...doc.querySelectorAll("body *")]
            .filter(el => el.getBoundingClientRect().right > #{@width} + 1)
            .slice(0, 3)
            .map(el => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") + "." + [...el.classList].slice(0, 3).join("."))
          return (wide > #{@width} ? "TOO WIDE " : "ok ") + f.getAttribute("src") + " " + wide + "px" +
            (culprits.length ? " (" + culprits.join(", ") + ")" : "")
        })
        document.getElementById("report").textContent = lines.join("\\n") + "\\ndone"
      })
    </script>
    </body></html>
    """
  end
end
