defmodule TabWeb.MCPTest do
  @moduledoc """
  Phase 5 end to end over HTTP, no network: the sign-in flow (CIMD and DCR),
  tokens, scopes, and the tools, with the database deciding what each person
  sees and saves (docs/specification.md, "Tests that must pass before phase 6").
  """
  use TabWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Tab.AccountsFixtures

  alias Tab.{Accounts, Groups, Ledger, OAuth, Repo}
  alias Tab.Accounts.Scope
  alias Tab.OAuth.{CIMD, Connection, Token}

  @cimd "https://claude.example/oauth/client.json"
  @redirect "http://localhost/callback"

  setup do
    priya = user_fixture()
    marcus = user_fixture()
    priya_scope = Scope.for_user(priya)
    marcus_scope = Scope.for_user(marcus)
    Accounts.update_profile(priya_scope, %{display_name: "Priya"})
    Accounts.update_profile(marcus_scope, %{display_name: "Marcus"})

    {:ok, house} = Groups.create_group(priya_scope, %{name: "Elm Street"})
    {:ok, {token, _}} = Groups.create_invite(priya_scope, house.id)
    {:ok, _} = Groups.accept_invite(marcus_scope, token)
    {:ok, landlord} = Groups.create_counterparty(priya_scope, house.id, %{name: "Landlord"})

    # A group Priya isn't in.
    {:ok, other} = Groups.create_group(marcus_scope, %{name: "Marcus Solo"})

    Req.Test.stub(CIMD, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("cache-control", "max-age=600")
      |> Req.Test.json(%{
        "client_id" => @cimd,
        "client_name" => "Claude Code",
        "redirect_uris" => [@redirect]
      })
    end)

    %{
      priya: priya,
      marcus: marcus,
      priya_scope: priya_scope,
      marcus_scope: marcus_scope,
      house: house,
      other: other,
      landlord: landlord
    }
  end

  ## Helpers

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp authorize_params(client_id, challenge, extra \\ %{}) do
    Map.merge(
      %{
        "client_id" => client_id,
        "redirect_uri" => "http://127.0.0.1:53999/callback",
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "resource" => OAuth.resource(),
        "state" => "xyz",
        "scope" => "tab:read tab:write"
      },
      extra
    )
  end

  # Signs `scope`'s person in through the consent logic and swaps the code.
  defp sign_in(scope, opts \\ []) do
    client_id = opts[:client_id] || @cimd
    {verifier, challenge} = pkce()
    {:ok, request} = OAuth.check_request(authorize_params(client_id, challenge))
    url = OAuth.approve(scope, request, Keyword.get(opts, :write, true))
    code = URI.parse(url).query |> URI.decode_query() |> Map.fetch!("code")

    conn =
      post(build_conn(), "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier,
        "client_id" => client_id,
        "redirect_uri" => "http://127.0.0.1:53999/callback",
        "resource" => OAuth.resource()
      })

    json_response(conn, 200)
  end

  defp rpc(token, method, params \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end

  defp tool(token, name, args) do
    conn = rpc(token, "tools/call", %{name: name, arguments: args})
    %{"result" => result} = json_response(conn, 200)
    result
  end

  ## The sign-in flow

  test "without a token, /mcp points at the metadata, which points at the issuer" do
    conn = post(build_conn(), "/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/list"})
    assert conn.status == 401
    [challenge] = get_resp_header(conn, "www-authenticate")

    assert challenge =~
             ~s(resource_metadata="#{OAuth.issuer()}/.well-known/oauth-protected-resource/mcp")

    assert challenge =~ ~s(scope="tab:read tab:write")

    prm = build_conn() |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)
    assert prm["resource"] == OAuth.resource()
    assert prm["authorization_servers"] == [OAuth.issuer()]

    as = build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)
    assert as["code_challenge_methods_supported"] == ["S256"]
    assert as["client_id_metadata_document_supported"] == true
    assert as["token_endpoint_auth_methods_supported"] == ["none"]
    assert as["authorization_response_iss_parameter_supported"] == true
  end

  test "a client asking for the challenge's scopes gets the write box" do
    conn = post(build_conn(), "/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/list"})
    [challenge] = get_resp_header(conn, "www-authenticate")
    [_, scope] = Regex.run(~r/scope="([^"]+)"/, challenge)
    {_verifier, code_challenge} = pkce()

    assert {:ok, %{scopes: ["tab:read", "tab:write"]}} =
             OAuth.check_request(authorize_params(@cimd, code_challenge, %{"scope" => scope}))
  end

  test "a CIMD client signs in and calls a tool", %{priya_scope: scope} do
    tokens = sign_in(scope)
    assert tokens["token_type"] == "Bearer"
    assert tokens["expires_in"] == 3600
    assert tokens["scope"] == "tab:read tab:write"

    result = tool(tokens["access_token"], "list_groups", %{})

    assert [%{"name" => "Elm Street", "members" => members}] =
             result["structuredContent"]["groups"]

    assert Enum.map(members, & &1["name"]) |> Enum.sort() == ["Marcus", "Priya"]
  end

  test "a DCR client registers, signs in, and calls a tool", %{priya_scope: scope} do
    reg =
      build_conn()
      |> post("/oauth/register", %{
        "client_name" => "claude.ai",
        "redirect_uris" => ["http://localhost/callback"],
        "token_endpoint_auth_method" => "none"
      })
      |> json_response(201)

    assert "tab_c_" <> _ = reg["client_id"]
    tokens = sign_in(scope, client_id: reg["client_id"])

    assert %{"result" => %{"tools" => tools}} =
             json_response(rpc(tokens["access_token"], "tools/list"), 200)

    assert length(tools) == 7

    bad =
      build_conn() |> post("/oauth/register", %{"redirect_uris" => ["http://evil.example/cb"]})

    assert json_response(bad, 400)["error"] == "invalid_client_metadata"
  end

  test "the authorize request is checked before anything happens" do
    {_verifier, challenge} = pkce()
    ok = authorize_params(@cimd, challenge)

    assert {:ok, %{client: %{name: "Claude Code"}}} = OAuth.check_request(ok)

    # Loopback redirects match on any port.
    assert {:ok, _} =
             OAuth.check_request(%{ok | "redirect_uri" => "http://localhost:4242/callback"})

    # Untrusted return address: shown, never redirected to.
    assert {:error, :no_redirect, _} =
             OAuth.check_request(%{ok | "redirect_uri" => "https://evil.example/callback"})

    assert {:error, :no_redirect, _} = OAuth.check_request(%{ok | "client_id" => "nobody"})

    for {key, value, error} <- [
          {"code_challenge_method", "plain", "invalid_request"},
          {"code_challenge", nil, "invalid_request"},
          {"resource", "https://elsewhere.example/mcp", "invalid_target"},
          {"scope", "admin", "invalid_scope"},
          {"response_type", "token", "unsupported_response_type"}
        ] do
      assert {:error, url} = OAuth.check_request(Map.put(ok, key, value))
      query = URI.decode_query(URI.parse(url).query)
      assert query["error"] == error
      assert query["state"] == "xyz"
      assert query["iss"] == OAuth.issuer()
    end
  end

  test "the approve redirect carries code, state, and iss", %{priya_scope: scope} do
    {_verifier, challenge} = pkce()
    {:ok, request} = OAuth.check_request(authorize_params(@cimd, challenge))

    query =
      OAuth.approve(scope, request, true) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    assert %{"code" => _, "state" => "xyz", "iss" => iss} = query
    assert iss == OAuth.issuer()
  end

  test "a wrong verifier, a reused code, and a mismatched redirect are refused", %{
    priya_scope: scope
  } do
    {verifier, challenge} = pkce()
    {:ok, request} = OAuth.check_request(authorize_params(@cimd, challenge))

    code =
      OAuth.approve(scope, request, true)
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()
      |> Map.fetch!("code")

    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "code_verifier" => verifier,
      "client_id" => @cimd,
      "redirect_uri" => "http://127.0.0.1:53999/callback",
      "resource" => OAuth.resource()
    }

    wrong =
      post(build_conn(), "/oauth/token", %{form | "code_verifier" => String.duplicate("a", 43)})

    assert json_response(wrong, 400)["error"] == "invalid_grant"

    elsewhere =
      post(build_conn(), "/oauth/token", %{form | "redirect_uri" => "http://localhost/other"})

    assert json_response(elsewhere, 400)["error"] == "invalid_grant"

    good = post(build_conn(), "/oauth/token", form) |> json_response(200)

    assert get_resp_header(post(build_conn(), "/oauth/token", form), "cache-control") == [
             "no-store"
           ]

    # The second use failed and took the first use's tokens with it.
    assert %{status: 401} = rpc(good["access_token"], "tools/list")
  end

  test "CIMD fetches refuse private addresses and documents that don't match" do
    assert {:error, :private_address} = CIMD.fetch("https://127.0.0.1/client.json")
    assert {:error, :private_address} = CIMD.fetch("https://localhost/client.json")
    assert {:error, :bad_client_id} = CIMD.fetch("http://claude.example/client.json")
    assert {:error, :bad_client_id} = CIMD.fetch("https://claude.example/")

    Req.Test.stub(
      CIMD,
      &Req.Test.json(&1, %{
        "client_id" => "https://other.example/x",
        "redirect_uris" => [@redirect]
      })
    )

    assert {:error, :bad_document} = CIMD.fetch("https://claude.example/client.json")

    Req.Test.stub(
      CIMD,
      &Req.Test.json(&1, %{"client_id" => @cimd, "redirect_uris" => ["http://evil.example/cb"]})
    )

    assert {:error, :bad_document} = CIMD.fetch(@cimd)

    Req.Test.stub(CIMD, &Plug.Conn.send_resp(&1, 200, String.duplicate("x", 20_000)))
    assert {:error, _} = CIMD.fetch(@cimd)
  end

  ## Tokens

  test "expired or wrong-resource tokens get 401", %{priya_scope: scope} do
    %{"access_token" => access} = sign_in(scope)
    hash = :crypto.hash(:sha256, access)

    Repo.update_all(from(t in Token, where: t.token_hash == ^hash),
      set: [resource: "https://elsewhere.example/mcp"]
    )

    assert %{status: 401} = rpc(access, "tools/list")

    %{"access_token" => access} = sign_in(scope)
    hash = :crypto.hash(:sha256, access)

    Repo.update_all(from(t in Token, where: t.token_hash == ^hash),
      set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
    )

    conn = rpc(access, "tools/list")
    assert conn.status == 401
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")
  end

  test "refresh tokens rotate, and a used one revokes the connection", %{priya_scope: scope} do
    first = sign_in(scope)

    refresh = fn token ->
      post(build_conn(), "/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => token,
        "client_id" => @cimd,
        "resource" => OAuth.resource()
      })
    end

    second = refresh.(first["refresh_token"]) |> json_response(200)
    assert second["refresh_token"] != first["refresh_token"]
    assert %{status: 200} = rpc(second["access_token"], "tools/list")

    # The old refresh token coming back means it leaked.
    assert json_response(refresh.(first["refresh_token"]), 400)["error"] == "invalid_grant"
    assert %{status: 401} = rpc(second["access_token"], "tools/list")
    assert json_response(refresh.(second["refresh_token"]), 400)["error"] == "invalid_grant"
  end

  test "Disconnect on the You page stops the next call", %{priya: priya, priya_scope: scope} do
    %{"access_token" => access} = sign_in(scope)
    assert %{status: 200} = rpc(access, "tools/list")

    conn = build_conn() |> log_in_user(priya)
    {:ok, lv, html} = live(conn, ~p"/profile")
    [connection] = Repo.all(Connection)
    assert html =~ "connection-#{connection.id}"
    lv |> element("#disconnect-#{connection.id}") |> render_click()
    refute has_element?(lv, "#connection-#{connection.id}")
    assert has_element?(lv, "#no-connections")

    assert %{status: 401} = rpc(access, "tools/list")
  end

  test "RFC 7009 revocation stops a token", %{priya_scope: scope} do
    %{"access_token" => access} = sign_in(scope)
    assert %{status: 200} = post(build_conn(), "/oauth/revoke", %{"token" => access})
    assert %{status: 401} = rpc(access, "tools/list")
  end

  ## Scopes

  test "a read-only connection can't add an expense", %{priya_scope: scope, house: house} do
    %{"access_token" => access, "scope" => "tab:read"} = sign_in(scope, write: false)

    conn =
      rpc(access, "tools/call", %{
        name: "add_expense",
        arguments: %{group: "Elm Street", description: "Groceries", amount: "43.00"}
      })

    assert conn.status == 403
    [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
    assert challenge =~ ~s(scope="tab:write")
    assert {:ok, []} = Ledger.list_expenses(scope, house.id)

    # Reading still works.
    assert %{"structuredContent" => _} = tool(access, "get_balances", %{})
  end

  ## The database decides

  test "tools never show Marcus's private expenses or another group", ctx do
    {:ok, _} =
      Ledger.create_expense(ctx.marcus_scope, ctx.house.id, %{
        description: "Marcus's own",
        amount_cents: 900,
        date: ~D[2026-10-10],
        paid_by: ctx.marcus.id,
        visibility: "private",
        split: %{"type" => "equal", "entries" => [%{"user_id" => ctx.marcus.id}]}
      })

    %{"access_token" => access} = sign_in(ctx.priya_scope)

    expenses = tool(access, "list_recent_expenses", %{group: "Elm Street"})
    assert expenses["structuredContent"]["expenses"] == []

    other = tool(access, "list_recent_expenses", %{group: "Marcus Solo"})
    assert other["isError"]
    assert hd(other["content"])["text"] =~ "No group called Marcus Solo"

    # Even past the tool's own group lookup, Postgres refuses.
    assert {:error, _} =
             Ledger.create_expense(Scope.for_claude(ctx.priya), ctx.other.id, %{
               description: "Sneaky",
               amount_cents: 100,
               date: ~D[2026-10-10],
               paid_by: ctx.priya.id,
               split: %{"type" => "equal", "entries" => [%{"user_id" => ctx.priya.id}]}
             })

    assert {:ok, []} = Ledger.list_expenses(ctx.marcus_scope, ctx.other.id)
  end

  ## Ledger rules hold through Claude

  test "add_expense saves at once, marked from Claude, and emails the split", ctx do
    %{"access_token" => access} = sign_in(ctx.priya_scope)

    result =
      tool(access, "add_expense", %{
        group: "elm",
        description: "Groceries",
        amount: "43.10",
        date: "2026-10-15"
      })

    assert %{"saved" => true, "shares" => shares, "paid_by" => "Priya (you)"} =
             result["structuredContent"]

    assert Enum.map(shares, & &1["amount"]) |> Enum.sort() == ["21.55", "21.55"]

    {:ok, [expense]} = Ledger.list_expenses(ctx.marcus_scope, ctx.house.id)
    assert expense.via == "claude"
    assert expense.created_by == ctx.priya.id
    marcus_email = ctx.marcus.email
    assert_received {:email, %{to: [{_, ^marcus_email}], subject: _}}

    # The web form's expenses stay "web".
    {:ok, web} =
      Ledger.create_expense(ctx.priya_scope, ctx.house.id, %{
        description: "Rent",
        amount_cents: 1000,
        date: ~D[2026-10-01],
        paid_by: ctx.priya.id,
        split: %{
          "type" => "equal",
          "entries" => [%{"user_id" => ctx.priya.id}, %{"user_id" => ctx.marcus.id}]
        }
      })

    assert Repo.reload!(web).via == "web"

    # Splits by name, with a counterparty and a tiered split.
    tiered =
      tool(access, "add_expense", %{
        description: "Power",
        amount: "100",
        split: %{
          type: "tiered",
          with: [%{who: "Landlord", value: "20"}],
          rest: %{
            type: "percentage",
            with: [%{who: "me", value: "60"}, %{who: "Marcus", value: "40"}]
          }
        }
      })

    shares = Map.new(tiered["structuredContent"]["shares"], &{&1["who"], &1["amount"]})
    assert shares == %{"Landlord" => "20.00", "Priya (you)" => "48.00", "Marcus" => "32.00"}

    # A split that doesn't add up comes back as words, nothing saved.
    bad =
      tool(access, "add_expense", %{
        description: "Bad",
        amount: "10",
        split: %{type: "exact", with: [%{who: "me", value: "3"}]}
      })

    assert bad["isError"]
    assert hd(bad["content"])["text"] =~ "didn't save"
  end

  test "record_payment: pending to a member, counted with a counterparty", ctx do
    %{"access_token" => access} = sign_in(ctx.priya_scope)

    member = tool(access, "record_payment", %{to: "Marcus", amount: "20", method: "venmo"})

    assert %{"status" => "pending", "in_words" => "Waiting for Marcus to confirm it in Tab."} =
             member["structuredContent"]

    outside = tool(access, "record_payment", %{to: "Landlord", amount: "500", method: "check"})
    assert outside["structuredContent"]["status"] == "self_attested"

    {:ok, payments} = Ledger.list_payments(ctx.marcus_scope, ctx.house.id)
    assert Enum.all?(payments, &(&1.via == "claude"))
  end

  test "balances, settle-up, and bills to check read in plain terms", ctx do
    {:ok, _} =
      Ledger.create_expense(ctx.marcus_scope, ctx.house.id, %{
        description: "Internet",
        amount_cents: 6_000,
        date: ~D[2026-10-10],
        paid_by: ctx.marcus.id,
        split: %{
          "type" => "equal",
          "entries" => [%{"user_id" => ctx.priya.id}, %{"user_id" => ctx.marcus.id}]
        }
      })

    %{"access_token" => access} = sign_in(ctx.priya_scope)

    nets = tool(access, "get_balances", %{})["structuredContent"]["groups"]
    assert [%{"group" => "Elm Street", "net" => "-30.00", "in_words" => "you owe $30.00"}] = nets

    group = tool(access, "get_balances", %{group: "Elm Street"})["structuredContent"]

    assert group["balances"] == [
             %{"owes" => "Priya (you)", "owed" => "Marcus", "amount" => "30.00"}
           ]

    settle = tool(access, "suggest_settle_up", %{group: "Elm Street"})["structuredContent"]

    assert settle["payments"] == [
             %{"from" => "Priya (you)", "to" => "Marcus", "amount" => "30.00"}
           ]

    assert tool(access, "list_bills_to_check", %{})["structuredContent"] == %{"bills" => []}
  end

  ## The protocol

  test "both eras: initialize for older clients, server/discover and _meta for 2026-07-28", %{
    priya_scope: scope
  } do
    %{"access_token" => access} = sign_in(scope)

    init =
      rpc(access, "initialize", %{
        protocolVersion: "2025-06-18",
        capabilities: %{},
        clientInfo: %{name: "t", version: "1"}
      })

    assert %{"result" => %{"protocolVersion" => "2025-06-18", "serverInfo" => %{"name" => "tab"}}} =
             json_response(init, 200)

    discover =
      rpc(access, "server/discover", %{
        _meta: %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      })

    assert %{"result" => %{"supportedVersions" => ["2026-07-28" | _], "resultType" => "complete"}} =
             json_response(discover, 200)

    old =
      rpc(access, "tools/list", %{
        _meta: %{"io.modelcontextprotocol/protocolVersion" => "1900-01-01"}
      })

    assert %{"error" => %{"code" => -32_022, "data" => %{"requested" => "1900-01-01"}}} =
             json_response(old, 200)

    unknown = rpc(access, "nope")
    assert %{"error" => %{"code" => -32_601}} = json_response(unknown, 200)

    note =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> access)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"}))

    assert note.status == 202

    get = build_conn() |> put_req_header("authorization", "Bearer " <> access) |> get("/mcp")
    assert get.status == 405

    foreign =
      build_conn()
      |> put_req_header("origin", "https://evil.example")
      |> put_req_header("authorization", "Bearer " <> access)
      |> post("/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/list"})

    assert foreign.status == 403
  end

  ## The consent page

  test "the consent page connects, with or without write", %{priya: priya} do
    {_verifier, challenge} = pkce()
    conn = build_conn() |> log_in_user(priya)
    query = URI.encode_query(authorize_params(@cimd, challenge))

    {:ok, lv, html} = live(conn, "/oauth/authorize?" <> query)
    assert html =~ "Connect Claude Code"
    assert html =~ "From claude.example"

    assert {:error, {:redirect, %{to: to}}} =
             lv |> form("#consent-form", %{"write" => "false"}) |> render_submit()

    assert to =~ "http://127.0.0.1:53999/callback?"
    assert [%Connection{scopes: ["tab:read"]}] = Repo.all(Connection)

    {:ok, lv, _} = live(conn, "/oauth/authorize?" <> query)
    assert {:error, {:redirect, %{to: to}}} = lv |> element("#deny") |> render_click()
    assert URI.decode_query(URI.parse(to).query)["error"] == "access_denied"
  end

  test "signed out, the consent page sends people to sign in first" do
    {_verifier, challenge} = pkce()
    query = URI.encode_query(authorize_params(@cimd, challenge))

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), "/oauth/authorize?" <> query)
  end

  test "TAB_MCP=off turns it all off", %{priya_scope: scope} do
    %{"access_token" => access} = sign_in(scope)
    Application.put_env(:tab, :mcp, false)
    on_exit(fn -> Application.put_env(:tab, :mcp, true) end)

    assert %{status: 404} = rpc(access, "tools/list")
    assert %{status: 404} = get(build_conn(), "/.well-known/oauth-authorization-server")
  end
end
