defmodule Tab.OAuth do
  @moduledoc """
  Tab's own OAuth 2.1 server, for the MCP server at `/mcp`
  (docs/specification.md, "Phase 5").

  Clients register by metadata document (CIMD) or by posting to
  `/oauth/register` (DCR). A person approves on the consent page, which makes
  a connection (as them, under row-level security) and a one-minute code.
  The code, with its PKCE verifier, buys a 1-hour access token and a 30-day
  refresh token, both bound to the MCP server's URI. Refresh tokens rotate;
  presenting a used one revokes the connection.

  Clients, codes, and tokens are read before anyone is known, so this module
  handles them as the connection owner, the way `Tab.Accounts` handles
  `users_tokens`. Nothing else in the app touches those tables. Connections
  are the person's, and listing or revoking them runs as the person.
  """
  import Ecto.Query

  alias Tab.Accounts.{Scope, User}
  alias Tab.OAuth.{CIMD, Client, Code, Connection, Token}
  alias Tab.Repo

  @scopes ~w(tab:read tab:write)
  @code_ttl 60
  @access_ttl 3_600
  @refresh_ttl 30 * 86_400

  def scopes, do: @scopes

  @doc "Whether the MCP server and these endpoints are on (`TAB_MCP`)."
  def enabled?, do: Application.get_env(:tab, :mcp, true)

  @doc "The issuer: the app's own origin, like `https://tab.example.com`."
  def issuer, do: TabWeb.Endpoint.url()

  @doc "The MCP server's canonical URI; tokens are bound to it."
  def resource, do: issuer() <> "/mcp"

  ## Clients

  @doc """
  Finds the client behind a `client_id`: a CIMD URL (fetched, or cached while
  fresh) or a registered id. `{:ok, client}` or `{:error, :unknown_client}`.
  """
  def get_client(client_id, now \\ now())

  def get_client("https://" <> _ = url, now) do
    case Repo.get_by(Client, client_id: url) do
      %Client{kind: "cimd", fresh_until: fresh} = client when not is_nil(fresh) ->
        if DateTime.compare(fresh, now) == :gt, do: {:ok, client}, else: refresh_cimd(url, now)

      _ ->
        refresh_cimd(url, now)
    end
  end

  def get_client(client_id, _now) when is_binary(client_id) do
    case Repo.get_by(Client, client_id: client_id, kind: "dcr") do
      %Client{} = client -> {:ok, client}
      nil -> {:error, :unknown_client}
    end
  end

  def get_client(_, _), do: {:error, :unknown_client}

  defp refresh_cimd(url, now) do
    case CIMD.fetch(url) do
      {:ok, doc} ->
        fields = %{
          name: doc.name,
          redirect_uris: doc.redirect_uris,
          fetched_at: now,
          fresh_until: DateTime.add(now, doc.fresh_for),
          updated_at: now
        }

        Repo.insert!(
          struct(Client, Map.merge(fields, %{client_id: url, kind: "cimd", inserted_at: now})),
          on_conflict: [set: Map.to_list(fields)],
          conflict_target: :client_id
        )

        {:ok, Repo.get_by!(Client, client_id: url)}

      {:error, _} ->
        {:error, :unknown_client}
    end
  end

  @doc """
  Dynamic Client Registration (RFC 7591), public clients only. Takes the
  decoded JSON body; returns the client or `{:error, description}`.
  """
  def register_client(params, now \\ now()) do
    uris = params["redirect_uris"]
    method = params["token_endpoint_auth_method"] || "none"
    grants = params["grant_types"] || ["authorization_code"]

    cond do
      not (is_list(uris) and uris != [] and length(uris) <= 20) ->
        {:error, "redirect_uris is required"}

      not Enum.all?(uris, &redirect_uri_allowed?/1) ->
        {:error, "redirect_uris must be https, or http on localhost"}

      method != "none" ->
        {:error, "only public clients (token_endpoint_auth_method none)"}

      not (is_list(grants) and grants -- ["authorization_code", "refresh_token"] == []) ->
        {:error, "grant_types may be authorization_code and refresh_token"}

      true ->
        name =
          case params["client_name"] do
            n when is_binary(n) and n != "" -> String.slice(String.trim(n), 0, 200)
            _ -> URI.parse(hd(uris)).host || "An app"
          end

        client =
          Repo.insert!(%Client{
            client_id: "tab_c_" <> random(18),
            kind: "dcr",
            name: name,
            redirect_uris: uris,
            inserted_at: now,
            updated_at: now
          })

        {:ok, client}
    end
  end

  @doc """
  Whether a client may register this redirect URI: https anywhere, or http on
  a loopback host (a desktop app or CLI catching its own callback).

      iex> Tab.OAuth.redirect_uri_allowed?("https://claude.ai/api/mcp/auth_callback")
      true
      iex> Tab.OAuth.redirect_uri_allowed?("http://localhost/callback")
      true
      iex> Tab.OAuth.redirect_uri_allowed?("http://evil.example/callback")
      false
  """
  def redirect_uri_allowed?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: h, fragment: nil} when is_binary(h) and h != "" -> true
      %URI{scheme: "http", host: h, fragment: nil} -> loopback?(h)
      _ -> false
    end
  end

  def redirect_uri_allowed?(_), do: false

  @doc """
  Whether `uri` is one of the client's redirect URIs. Exact, except loopback
  ones match on any port and either loopback name, since Claude Code picks a
  free port each time.
  """
  def redirect_matches?(%Client{redirect_uris: registered}, uri) when is_binary(uri) do
    uri in registered or
      Enum.any?(registered, fn reg ->
        a = URI.parse(reg)
        b = URI.parse(uri)

        a.scheme == "http" and b.scheme == "http" and loopback?(a.host) and loopback?(b.host) and
          a.path == b.path and a.query == b.query and is_nil(b.fragment)
      end)
  end

  def redirect_matches?(_, _), do: false

  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  ## Authorizing

  @doc """
  Checks an authorization request's parameters. `{:ok, request}` with the
  client, or `{:error, :no_redirect, message}` when the client or redirect
  can't be trusted (show it, don't redirect), or `{:error, redirect_url}`
  for errors the client should hear about.
  """
  def check_request(params) do
    with {:ok, client} <- get_client(params["client_id"]) |> no_redirect("Unknown app"),
         redirect when is_binary(redirect) <- params["redirect_uri"],
         true <- redirect_matches?(client, redirect) do
      state = params["state"]
      error = &{:error, error_redirect(redirect, state, &1, &2)}
      scopes = requested_scopes(params["scope"])

      cond do
        params["response_type"] != "code" ->
          error.("unsupported_response_type", "response_type must be code")

        params["code_challenge_method"] != "S256" ->
          error.("invalid_request", "PKCE with S256 is required")

        not valid_challenge?(params["code_challenge"]) ->
          error.("invalid_request", "code_challenge is missing or malformed")

        not resource_ok?(params["resource"]) ->
          error.("invalid_target", "resource must be #{resource()}")

        scopes == :invalid ->
          error.("invalid_scope", "scopes are tab:read and tab:write")

        true ->
          {:ok,
           %{
             client: client,
             redirect_uri: redirect,
             state: state,
             code_challenge: params["code_challenge"],
             scopes: scopes
           }}
      end
    else
      {:error, :no_redirect, message} -> {:error, :no_redirect, message}
      _ -> {:error, :no_redirect, "That app's return address doesn't match what it registered."}
    end
  end

  defp no_redirect({:ok, _} = ok, _), do: ok
  defp no_redirect(_, message), do: {:error, :no_redirect, message}

  # No scope asked for means read and write; the consent page decides write.
  defp requested_scopes(nil), do: @scopes
  defp requested_scopes(""), do: @scopes

  defp requested_scopes(scope) when is_binary(scope) do
    asked = String.split(scope)
    # `offline_access` asks for a refresh token, which Tab always gives.
    known = Enum.filter(asked, &(&1 in @scopes))

    cond do
      asked -- (@scopes ++ ["offline_access"]) != [] -> :invalid
      known == [] -> @scopes
      true -> Enum.uniq(["tab:read" | known])
    end
  end

  defp requested_scopes(_), do: :invalid

  defp valid_challenge?(c), do: is_binary(c) and c =~ ~r/^[A-Za-z0-9_-]{43}$/

  defp resource_ok?(nil), do: false
  defp resource_ok?(r), do: String.trim_trailing(r, "/") == resource()

  @doc """
  The person approved: makes their connection (as them) and a code, and
  returns the URL to send the browser to. `write?` is the consent page's tick
  box; without it the connection only reads.
  """
  def approve(%Scope{user: %User{}} = scope, request, write?, now \\ now()) do
    scopes = if write?, do: request.scopes, else: request.scopes -- ["tab:write"]

    {:ok, connection} =
      Tab.DBError.as_user(scope, fn ->
        Repo.insert(%Connection{
          id: Ecto.UUID.generate(),
          client_id: request.client.id,
          scopes: scopes,
          inserted_at: now,
          updated_at: now
        })
      end)

    code = random(32)

    Repo.insert!(%Code{
      connection_id: connection.id,
      code_hash: hash(code),
      redirect_uri: request.redirect_uri,
      code_challenge: request.code_challenge,
      resource: resource(),
      expires_at: DateTime.add(now, @code_ttl),
      inserted_at: now,
      updated_at: now
    })

    with_params(request.redirect_uri, code: code, state: request.state, iss: issuer())
  end

  @doc "The person said no."
  def deny(request) do
    error_redirect(request.redirect_uri, request.state, "access_denied", "The person said no")
  end

  defp error_redirect(redirect, state, error, description) do
    with_params(redirect,
      error: error,
      error_description: description,
      state: state,
      iss: issuer()
    )
  end

  defp with_params(url, params) do
    uri = URI.parse(url)
    params = Enum.reject(params, fn {_, v} -> is_nil(v) end)
    query = URI.encode_query((uri.query && URI.decode_query(uri.query) |> Map.to_list()) || [])

    extra = URI.encode_query(params)
    %{uri | query: Enum.join(Enum.reject([query, extra], &(&1 == "")), "&")} |> URI.to_string()
  end

  ## Tokens

  @doc """
  The token endpoint. Takes the form parameters; returns `{:ok, body}` or
  `{:error, error_code, description}` per RFC 6749 §5.2.
  """
  def token(params, now \\ now())

  def token(%{"grant_type" => "authorization_code"} = params, now) do
    with {:ok, code} <- find_code(params["code"]),
         {:ok, conn} <- live_connection(code.connection_id),
         :ok <- same_client(conn, params["client_id"]),
         :ok <- check(code.redirect_uri == params["redirect_uri"], "redirect_uri doesn't match"),
         :ok <- check(pkce_ok?(code.code_challenge, params["code_verifier"]), "PKCE check failed"),
         :ok <- check(resource_ok?(params["resource"] || code.resource), "wrong resource"),
         :ok <- check(DateTime.compare(code.expires_at, now) == :gt, "code expired"),
         :ok <- use_code(code, now) do
      {:ok, issue(conn, code.id, now)}
    end
  end

  def token(%{"grant_type" => "refresh_token"} = params, now) do
    with {:ok, old} <- find_token(params["refresh_token"], "refresh"),
         {:ok, conn} <- live_connection(old.connection_id),
         :ok <- same_client(conn, params["client_id"]),
         :ok <- check(resource_ok?(params["resource"] || old.resource), "wrong resource"),
         :ok <- check(DateTime.compare(old.expires_at, now) == :gt, "refresh token expired"),
         :ok <- use_refresh(old, conn, now) do
      {:ok, issue(conn, nil, now)}
    end
  end

  def token(_, _), do: {:error, "unsupported_grant_type", "grant_type not supported"}

  defp check(true, _), do: :ok
  defp check(_, message), do: {:error, "invalid_grant", message}

  defp find_code(code) when is_binary(code) do
    case Repo.get_by(Code, code_hash: hash(code)) do
      %Code{} = c -> {:ok, c}
      nil -> {:error, "invalid_grant", "unknown code"}
    end
  end

  defp find_code(_), do: {:error, "invalid_request", "code is required"}

  defp find_token(token, kind) when is_binary(token) do
    case Repo.get_by(Token, token_hash: hash(token), kind: kind) do
      %Token{} = t -> {:ok, t}
      nil -> {:error, "invalid_grant", "unknown token"}
    end
  end

  defp find_token(_, _), do: {:error, "invalid_request", "token is required"}

  defp live_connection(id) do
    case Repo.get(Connection, id) |> Repo.preload(:client) do
      %Connection{revoked_at: nil} = c -> {:ok, c}
      _ -> {:error, "invalid_grant", "the connection was disconnected"}
    end
  end

  defp same_client(%Connection{client: %Client{client_id: id}}, id), do: :ok
  defp same_client(_, _), do: {:error, "invalid_client", "client_id doesn't match"}

  defp pkce_ok?(challenge, verifier)
       when is_binary(verifier) and byte_size(verifier) in 43..128 do
    computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  defp pkce_ok?(_, _), do: false

  # A code works once. Seeing it again means someone else has it: every
  # token it bought is revoked.
  defp use_code(code, now) do
    {count, _} =
      from(c in Code, where: c.id == ^code.id and is_nil(c.used_at))
      |> Repo.update_all(set: [used_at: now])

    if count == 1 do
      :ok
    else
      from(t in Token, where: t.code_id == ^code.id and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])

      {:error, "invalid_grant", "code already used"}
    end
  end

  # Refresh tokens rotate. A used one coming back means it leaked: the
  # whole connection goes.
  defp use_refresh(old, conn, now) do
    {count, _} =
      from(t in Token, where: t.id == ^old.id and is_nil(t.used_at) and is_nil(t.revoked_at))
      |> Repo.update_all(set: [used_at: now])

    if count == 1 do
      :ok
    else
      revoke_connection(conn.id, now)
      {:error, "invalid_grant", "refresh token already used; reconnect"}
    end
  end

  defp issue(conn, code_id, now) do
    access = "tab_at_" <> random(32)
    refresh = "tab_rt_" <> random(32)

    for {kind, token, ttl} <- [
          {"access", access, @access_ttl},
          {"refresh", refresh, @refresh_ttl}
        ] do
      Repo.insert!(%Token{
        connection_id: conn.id,
        code_id: code_id,
        kind: kind,
        token_hash: hash(token),
        resource: resource(),
        expires_at: DateTime.add(now, ttl),
        inserted_at: now,
        updated_at: now
      })
    end

    %{
      access_token: access,
      token_type: "Bearer",
      expires_in: @access_ttl,
      refresh_token: refresh,
      scope: Enum.join(conn.scopes, " ")
    }
  end

  @doc "RFC 7009: revokes a token the client holds. Always succeeds."
  def revoke_token(token, now \\ now()) when is_binary(token) do
    from(t in Token, where: t.token_hash == ^hash(token) and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  defp revoke_connection(id, now) do
    from(c in Connection, where: c.id == ^id and is_nil(c.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])
  end

  @doc """
  Checks a bearer token for `/mcp`. `{:ok, user, connection}`, or
  `{:error, :invalid_token}` for anything expired, revoked, disconnected,
  unknown, or bound to another resource.
  """
  def verify_access(token, now \\ now())

  def verify_access(token, now) when is_binary(token) do
    query =
      from t in Token,
        join: c in Connection,
        on: c.id == t.connection_id,
        join: u in User,
        on: u.id == c.user_id,
        where:
          t.token_hash == ^hash(token) and t.kind == "access" and is_nil(t.revoked_at) and
            t.expires_at > ^now and t.resource == ^resource() and is_nil(c.revoked_at),
        select: {u, c}

    case Repo.one(query) do
      {user, conn} ->
        touch(conn, now)
        {:ok, user, conn}

      nil ->
        {:error, :invalid_token}
    end
  end

  def verify_access(_, _), do: {:error, :invalid_token}

  # "Last used" on the You page; at most one write a minute per connection.
  defp touch(%Connection{last_used_at: last} = conn, now) do
    if is_nil(last) or DateTime.diff(now, last) >= 60 do
      from(c in Connection, where: c.id == ^conn.id)
      |> Repo.update_all(set: [last_used_at: now])
    end
  end

  ## The person's own connections

  @doc "The person's live connections, newest first, with each client's name."
  def list_connections(%Scope{} = scope) do
    Tab.DBError.as_user(scope, fn ->
      {:ok,
       from(c in Connection,
         where: is_nil(c.revoked_at),
         order_by: [desc: c.inserted_at],
         preload: [
           client: ^from(cl in Client, select: struct(cl, [:id, :name, :client_id, :kind]))
         ]
       )
       |> Repo.all()}
    end)
  end

  @doc "Disconnects one of the person's connections; its tokens stop working at once."
  def disconnect(%Scope{} = scope, id) do
    Tab.DBError.as_user(scope, fn ->
      case from(c in Connection, where: c.id == ^id and is_nil(c.revoked_at))
           |> Repo.update_all(set: [revoked_at: now(), updated_at: now()]) do
        {1, _} -> {:ok, :done}
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc "Clears registered (DCR) clients nobody connected within a day."
  def sweep_clients(now \\ now()) do
    cutoff = DateTime.add(now, -86_400)

    from(cl in Client,
      as: :cl,
      where:
        cl.kind == "dcr" and cl.inserted_at < ^cutoff and
          not exists(from(c in Connection, where: c.client_id == parent_as(:cl).id))
    )
    |> Repo.delete_all()
  end

  ## Helpers

  defp random(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
  defp hash(token), do: :crypto.hash(:sha256, token)
  defp now, do: DateTime.utc_now(:second)
end
