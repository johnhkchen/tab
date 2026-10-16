defmodule TabWeb.OAuthController do
  @moduledoc """
  The machine side of Tab's OAuth server (docs/specification.md, "Endpoints"):
  the two metadata documents, the token endpoint, client registration, and
  revocation. The consent page is `TabWeb.OAuthLive.Authorize`.
  """
  use TabWeb, :controller

  alias Tab.OAuth
  alias Tab.OAuth.RateLimit

  plug :enabled

  defp enabled(conn, _) do
    if OAuth.enabled?(), do: conn, else: conn |> send_resp(404, "") |> halt()
  end

  @doc "RFC 9728: where the MCP server's tokens come from."
  def protected_resource(conn, _params) do
    json(conn, %{
      resource: OAuth.resource(),
      authorization_servers: [OAuth.issuer()],
      scopes_supported: OAuth.scopes(),
      bearer_methods_supported: ["header"],
      resource_name: "Tab"
    })
  end

  @doc "RFC 8414: what this authorization server supports."
  def authorization_server(conn, _params) do
    issuer = OAuth.issuer()

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: issuer <> "/oauth/authorize",
      token_endpoint: issuer <> "/oauth/token",
      registration_endpoint: issuer <> "/oauth/register",
      revocation_endpoint: issuer <> "/oauth/revoke",
      scopes_supported: OAuth.scopes(),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      revocation_endpoint_auth_methods_supported: ["none"],
      client_id_metadata_document_supported: true,
      authorization_response_iss_parameter_supported: true
    })
  end

  def token(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case OAuth.token(params) do
      {:ok, body} ->
        json(conn, body)

      {:error, "invalid_client" = error, description} ->
        conn |> put_status(401) |> json(%{error: error, error_description: description})

      {:error, error, description} ->
        conn |> put_status(400) |> json(%{error: error, error_description: description})
    end
  end

  def register(conn, params) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    with :ok <- RateLimit.hit({:register, ip}, 20, 86_400),
         {:ok, client} <- OAuth.register_client(params) do
      conn
      |> put_status(201)
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        client_id: client.client_id,
        client_id_issued_at: DateTime.to_unix(client.inserted_at),
        client_name: client.name,
        redirect_uris: client.redirect_uris,
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"]
      })
    else
      {:error, seconds} when is_integer(seconds) ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(429)
        |> json(%{error: "too_many_requests"})

      {:error, description} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_client_metadata", error_description: description})
    end
  end

  def revoke(conn, %{"token" => token}) when is_binary(token) do
    :ok = OAuth.revoke_token(token)
    send_resp(conn, 200, "")
  end

  def revoke(conn, _params) do
    conn |> put_status(400) |> json(%{error: "invalid_request"})
  end
end
