defmodule Tab.OAuth.CIMD do
  @moduledoc """
  Fetches a client ID metadata document: the JSON an MCP client publishes at
  the URL it uses as its `client_id` (docs/specification.md, "Endpoints").

  The URL comes from whoever starts a sign-in, so the fetch is careful: https
  only, to a host that resolves to public addresses only (pinned for the
  connection, so DNS can't change its mind between the check and the fetch),
  no redirects, 5 seconds, 10 KB.
  """

  @max_bytes 10_240
  @min_fresh 300
  @max_fresh 86_400

  @doc """
  `{:ok, %{name:, redirect_uris:, fresh_for:}}` or `{:error, reason}`, where
  `fresh_for` is how many seconds to trust it, from `Cache-Control`.
  """
  def fetch(url) do
    with {:ok, uri} <- check_url(url),
         {:ok, ip} <- public_address(uri.host),
         {:ok, resp} <- get(uri, ip),
         {:ok, doc} <- decode(resp.body),
         :ok <- same_id(doc, url),
         {:ok, uris} <- redirect_uris(doc) do
      {:ok,
       %{
         name: name(doc, uri),
         redirect_uris: uris,
         fresh_for: fresh_for(resp)
       }}
    end
  end

  @doc "Whether `url` could be a metadata document URL: https, a host, a path."
  def check_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path, fragment: nil, userinfo: nil} = uri
      when is_binary(host) and host != "" and is_binary(path) and path not in ["", "/"] ->
        {:ok, uri}

      _ ->
        {:error, :bad_client_id}
    end
  end

  def check_url(_), do: {:error, :bad_client_id}

  @doc "The host's first address, if every address it resolves to is public."
  def public_address(host) do
    {mod, fun} = Application.get_env(:tab, :cimd_resolver, {__MODULE__, :resolve})

    case apply(mod, fun, [String.to_charlist(host)]) do
      {:ok, [ip | _] = ips} ->
        if Enum.all?(ips, &public?/1), do: {:ok, ip}, else: {:error, :private_address}

      _ ->
        {:error, :unresolvable}
    end
  end

  @doc false
  def resolve(host) do
    case :inet.parse_address(host) do
      {:ok, ip} ->
        {:ok, [ip]}

      _ ->
        v4 = with {:ok, ips} <- :inet.getaddrs(host, :inet), do: ips, else: (_ -> [])
        v6 = with {:ok, ips} <- :inet.getaddrs(host, :inet6), do: ips, else: (_ -> [])
        if v4 ++ v6 == [], do: {:error, :nxdomain}, else: {:ok, v4 ++ v6}
    end
  end

  @doc """
  Whether an address is out on the internet: not loopback, private, link-local,
  shared (CGNAT), multicast, reserved, or documentation space.

      iex> Tab.OAuth.CIMD.public?({160, 79, 104, 10})
      true
      iex> Tab.OAuth.CIMD.public?({10, 0, 0, 1})
      false
      iex> Tab.OAuth.CIMD.public?({0, 0, 0, 0, 0, 65535, 32512, 1})
      false
  """
  def public?({a, b, _, _} = ip) do
    not (a in [0, 10, 127] or a >= 224 or
           (a == 100 and b in 64..127) or
           (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or
           (a == 192 and b == 168) or
           (a == 198 and b in 18..19) or
           match?({192, 0, 0, _}, ip) or
           match?({192, 0, 2, _}, ip) or
           match?({198, 51, 100, _}, ip) or
           match?({203, 0, 113, _}, ip))
  end

  # IPv4-mapped (::ffff:a.b.c.d) is judged as the IPv4 address.
  def public?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: public?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  def public?({a, _, _, _, _, _, _, _} = ip) do
    # Global unicast is 2000::/3; within it, skip documentation (2001:db8::/32).
    a in 0x2000..0x3FFF and not match?({0x2001, 0x0DB8, _, _, _, _, _, _}, ip)
  end

  defp get(uri, ip) do
    options =
      Keyword.merge(
        [
          url: %{uri | host: ip_text(ip)},
          headers: [host: uri.host, accept: "application/json"],
          connect_options: [hostname: uri.host, timeout: 5_000],
          receive_timeout: 5_000,
          redirect: false,
          retry: false,
          decode_body: false,
          into: &cap/2
        ],
        Application.get_env(:tab, :cimd_req, [])
      )

    case Req.get(options) do
      {:ok, %{status: 200} = resp} -> {:ok, resp}
      {:ok, _} -> {:error, :fetch_failed}
      {:error, _} -> {:error, :fetch_failed}
    end
  end

  # Stops reading once the body passes the cap.
  defp cap({:data, data}, {req, resp}) do
    body = if(is_binary(resp.body), do: resp.body, else: "") <> data

    if byte_size(body) > @max_bytes,
      do: {:halt, {req, %{resp | status: 413, body: ""}}},
      else: {:cont, {req, %{resp | body: body}}}
  end

  defp ip_text(ip) when tuple_size(ip) == 4, do: ip |> :inet.ntoa() |> to_string()
  defp ip_text(ip), do: "[#{ip |> :inet.ntoa() |> to_string()}]"

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = doc} -> {:ok, doc}
      _ -> {:error, :bad_document}
    end
  end

  defp decode(_), do: {:error, :bad_document}

  defp same_id(%{"client_id" => url}, url), do: :ok
  defp same_id(_, _), do: {:error, :bad_document}

  defp redirect_uris(%{"redirect_uris" => [_ | _] = uris}) do
    if length(uris) <= 20 and Enum.all?(uris, &Tab.OAuth.redirect_uri_allowed?/1),
      do: {:ok, uris},
      else: {:error, :bad_document}
  end

  defp redirect_uris(_), do: {:error, :bad_document}

  defp name(%{"client_name" => name}, _uri) when is_binary(name) and name != "",
    do: String.slice(String.trim(name), 0, 200)

  defp name(_, uri), do: uri.host

  defp fresh_for(resp) do
    seconds =
      resp
      |> Req.Response.get_header("cache-control")
      |> Enum.find_value(fn value ->
        case Regex.run(~r/max-age=(\d+)/, value) do
          [_, n] -> String.to_integer(n)
          _ -> nil
        end
      end)

    (seconds || @min_fresh) |> max(@min_fresh) |> min(@max_fresh)
  end
end
