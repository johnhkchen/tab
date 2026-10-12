defmodule Tab.Inbox.Resend do
  @moduledoc """
  Resend's side of receiving mail: checking a webhook's signature and fetching
  the message it points at (docs/specification.md, "Forwarded email").

  Webhooks are signed the Svix way: HMAC-SHA256, keyed with the base64 part
  of the `whsec_` secret, over `"<svix-id>.<svix-timestamp>.<raw body>"`, sent
  as one or more space-separated `v1,<base64>` values in `svix-signature`.
  """

  @tolerance 300

  @doc "Whether a webhook's headers sign `body` with `secret`. `now` is Unix seconds."
  def verify(body, headers, secret, now \\ System.system_time(:second))

  def verify(
        body,
        %{"svix-id" => id, "svix-timestamp" => ts, "svix-signature" => sigs},
        secret,
        now
      )
      when is_binary(secret) and secret != "" do
    with {ts_int, ""} <- Integer.parse(ts),
         true <- abs(now - ts_int) <= @tolerance,
         {:ok, key} <- key(secret) do
      expected = :crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{body}") |> Base.encode64()

      sigs
      |> String.split(" ", trim: true)
      |> Enum.any?(fn
        "v1," <> sig -> Plug.Crypto.secure_compare(sig, expected)
        _ -> false
      end)
    else
      _ -> false
    end
  end

  def verify(_, _, _, _), do: false

  defp key("whsec_" <> b64), do: Base.decode64(b64)
  defp key(b64), do: Base.decode64(b64)

  @doc "Signs `body` the way Resend does. For tests and local trials."
  def sign(body, id, ts, secret) do
    {:ok, key} = key(secret)
    "v1," <> (:crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{body}") |> Base.encode64())
  end

  @doc """
  The received email `id`: `{:ok, %{to: [address], from:, subject:, raw: binary}}`,
  `{:error, :too_big}`, or `{:error, reason}` worth retrying.
  """
  def fetch(id, max_bytes) do
    with {:ok, %{status: 200, body: %{} = email}} <-
           Req.get(req(), url: "/emails/receiving/#{URI.encode(id)}"),
         %{"raw" => %{"download_url" => url}} <- email,
         {:ok, %{status: 200, body: raw}} when is_binary(raw) <- download(url, max_bytes) do
      {:ok,
       %{
         to: List.wrap(email["to"]) ++ List.wrap(email["received_for"]),
         from: email["from"],
         subject: email["subject"],
         raw: raw
       }}
    else
      {:error, :too_big} -> {:error, :too_big}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_raw}
    end
  end

  defp download(url, max_bytes) do
    # Stop reading past the cap rather than holding a huge message in memory.
    into = fn {:data, data}, {req, resp} ->
      body = (resp.body || "") <> data

      if byte_size(body) > max_bytes,
        do: {:halt, {req, %{resp | body: :too_big}}},
        else: {:cont, {req, %{resp | body: body}}}
    end

    case Req.get(Keyword.merge([url: url, into: into, retry: false], test_options())) do
      {:ok, %{body: :too_big}} -> {:error, :too_big}
      other -> other
    end
  end

  defp req do
    Req.new(
      Keyword.merge(
        [
          base_url: "https://api.resend.com",
          auth: {:bearer, Application.get_env(:tab, :resend_api_key) || ""},
          retry: false,
          receive_timeout: 30_000
        ],
        test_options()
      )
    )
  end

  defp test_options, do: Application.get_env(:tab, :resend_req, [])
end
