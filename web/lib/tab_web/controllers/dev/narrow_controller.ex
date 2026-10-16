defmodule TabWeb.Dev.NarrowController do
  @moduledoc """
  Development only (routed under /dev, which exists only with `dev_routes`).
  Signs in as a seeded demo person and shows every page in a 360 px frame,
  then reports any page that scrolls sideways. `mise run check:narrow` reads
  the report with headless Chrome; open it yourself to look at the pages.
  """
  use TabWeb, :controller

  alias Tab.{Accounts, Bills, Groups, Ledger, Statements}

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
    |> html(page(only(paths(scope), params["only"]), params["shots"] == "1"))
  end

  defp paths(scope) do
    {:ok, [group | _]} = Groups.list_groups(scope)
    {:ok, expenses} = Ledger.list_expenses(scope, group.id)
    expense = List.first(expenses)
    {:ok, templates} = Bills.list_templates(scope, group.id)
    template = List.first(templates)
    {:ok, balances} = Ledger.balances(scope, group.id)
    {:ok, items} = Tab.Inbox.list_items(scope)
    item = Enum.find(items, &(&1.status == "ready"))
    me = {:user, scope.user.id}
    debtor = Enum.find_value(balances, &(&1.creditor == me && &1.debtor))

    # A fresh statement link each time: the page needs a working token.
    statement =
      with {_, _} <- debtor,
           {:ok, token, _} <- Statements.create_link(scope, group.id, debtor) do
        ~p"/s/#{token}"
      else
        _ -> nil
      end

    consent = consent_path(scope)

    [
      ~p"/groups",
      ~p"/groups/#{group}",
      ~p"/groups/#{group}/expenses/new",
      expense && ~p"/groups/#{group}/expenses/#{expense}",
      expense && ~p"/groups/#{group}/expenses/#{expense}/edit",
      ~p"/groups/#{group}/settle",
      ~p"/groups/#{group}/members",
      ~p"/groups/#{group}/bills",
      ~p"/groups/#{group}/temporary",
      template && ~p"/groups/#{group}/expenses/new?template=#{template.id}",
      debtor && ~p"/groups/#{group}/remind/#{TabWeb.GroupData.party_key(debtor)}",
      statement,
      ~p"/s/not-a-real-token",
      ~p"/inbox",
      ~p"/inbox/forwarding",
      item && ~p"/inbox/#{item}",
      item && ~p"/groups/#{group}/expenses/new?item=#{item.id}",
      ~p"/profile",
      consent,
      # Hosted Tab's pages: run with TAB_EDITION=cloud (and TAB_ADMIN_EMAILS
      # including the demo person for /admin).
      cloud_path(scope, ~p"/plans"),
      cloud_path(scope, ~p"/admin"),
      ~p"/users/settings",
      ~p"/welcome",
      ~p"/join/not-a-real-token",
      ~p"/users/log-in"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp cloud_path(scope, path) do
    cond do
      not Tab.Billing.cloud?() -> nil
      path == "/admin" and not Tab.Billing.admin?(scope) -> nil
      true -> with(:ok <- Tab.Billing.start(scope.user), do: path)
    end
  end

  # The consent page needs a real client; the You page shows its connection.
  defp consent_path(scope) do
    client_id = "tab_c_narrow-demo-client"

    client =
      Tab.Repo.get_by(Tab.OAuth.Client, client_id: client_id) ||
        Tab.Repo.insert!(%Tab.OAuth.Client{
          client_id: client_id,
          kind: "dcr",
          name: "Claude Code",
          redirect_uris: ["http://localhost/callback"]
        })

    {:ok, connections} = Tab.OAuth.list_connections(scope)
    challenge = :crypto.hash(:sha256, "narrow") |> Base.url_encode64(padding: false)

    params = %{
      "client_id" => client.client_id,
      "redirect_uri" => "http://localhost:1234/callback",
      "response_type" => "code",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "resource" => Tab.OAuth.resource(),
      "state" => "narrow"
    }

    if connections == [] do
      {:ok, request} = Tab.OAuth.check_request(params)
      Tab.OAuth.approve(scope, request, true)
    end

    "/oauth/authorize?" <> URI.encode_query(params)
  end

  # `?only=/profile,/oauth` keeps the pages whose path starts with one of these.
  defp only(paths, nil), do: paths

  defp only(paths, prefixes) do
    prefixes = String.split(prefixes, ",", trim: true)
    Enum.filter(paths, fn path -> Enum.any?(prefixes, &String.starts_with?(path, &1)) end)
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
