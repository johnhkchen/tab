defmodule Tab.Inbox.Email do
  @moduledoc """
  Picks apart a raw forwarded email: who sent it, the subject, and the one part
  worth reading (docs/specification.md, "Which part of an email gets read"):
  the first PDF, else the first image, else the text body with HTML stripped.

  Uses gen_smtp's `:mimemail` with no charset conversion; text that isn't
  valid UTF-8 has its bad bytes replaced.
  """

  @images ~w(jpeg png gif webp)

  defstruct from: nil, subject: nil, text: "", part: nil, gmail_code: nil

  @type part :: {:pdf | :photo, content_type :: String.t(), filename :: String.t() | nil, binary}

  @doc "Parses a raw message. `{:error, :unreadable}` if it isn't MIME at all."
  def parse(raw) when is_binary(raw) do
    {_, _, headers, _, _} = mime = :mimemail.decode(raw, encoding: :none)
    parts = flatten(mime)
    from = header(headers, "from")
    subject = header(headers, "subject")
    text = body_text(parts)

    {:ok,
     %__MODULE__{
       from: from,
       subject: subject,
       text: text,
       part: Enum.find_value(parts, &pdf/1) || Enum.find_value(parts, &image/1),
       gmail_code: gmail_code(from, subject, text)
     }}
  rescue
    _ -> {:error, :unreadable}
  catch
    _, _ -> {:error, :unreadable}
  end

  @doc ~S"""
  The sender's address, lowercased, from a From header.

      iex> Tab.Inbox.Email.address("PG&E <Billing@PGE.com>")
      "billing@pge.com"
  """
  def address(nil), do: nil

  def address(from) do
    case Regex.run(~r/<([^>]+)>/, from) do
      [_, addr] -> String.downcase(String.trim(addr))
      _ -> from |> String.trim() |> String.downcase() |> nil_if_not_address()
    end
  end

  defp nil_if_not_address(s), do: if(String.contains?(s, "@"), do: s)

  @doc ~S"""
  The domain part of an address, without common mail subdomains.

      iex> Tab.Inbox.Email.domain("billing@mail.pge.com")
      "pge.com"
  """
  def domain(nil), do: nil

  def domain(address) do
    case String.split(address, "@") do
      [_, host] ->
        host
        |> String.split(".")
        |> then(fn labels -> if length(labels) > 2, do: Enum.take(labels, -2), else: labels end)
        |> Enum.join(".")

      _ ->
        nil
    end
  end

  defp flatten({type, subtype, headers, params, body}) when is_list(body),
    do: [{type, subtype, headers, params, nil} | Enum.flat_map(body, &flatten/1)]

  defp flatten({"message", "rfc822", _, _, inner}), do: flatten(inner)
  defp flatten(part), do: [part]

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> String.downcase(k) == name && clean(v) end)
  end

  defp pdf({"application", sub, _, params, body}) when is_binary(body) do
    name = filename(params)

    if sub == "pdf" or
         (sub == "octet-stream" and String.ends_with?(String.downcase(name || ""), ".pdf")),
       do: {:pdf, "application/pdf", name, body}
  end

  defp pdf(_), do: nil

  defp image({"image", sub, _, params, body}) when sub in @images and is_binary(body),
    do: {:photo, "image/#{sub}", filename(params), body}

  defp image(_), do: nil

  defp filename(params) do
    List.keyfind(params[:disposition_params] || [], "filename", 0, {nil, nil})
    |> elem(1)
    |> Kernel.||(
      params[:content_type_params]
      |> List.wrap()
      |> List.keyfind("name", 0, {nil, nil})
      |> elem(1)
    )
  end

  defp body_text(parts) do
    plain =
      for {"text", "plain", _, p, b} <- parts,
          is_binary(b),
          p[:disposition] != "attachment",
          do: b

    html =
      for {"text", "html", _, p, b} <- parts, is_binary(b), p[:disposition] != "attachment", do: b

    case {plain, html} do
      {[t | _], _} -> clean(t)
      {[], [h | _]} -> h |> strip_html() |> clean()
      _ -> ""
    end
    |> String.slice(0, 20_000)
  end

  @doc false
  def strip_html(html) do
    html
    |> String.replace(~r/<(script|style)[^>]*>.*?<\/\1>/is, " ")
    |> String.replace(~r/<br\s*\/?>|<\/(p|div|tr|li|h\d)>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/i, " ")
    |> String.replace(~r/&amp;/i, "&")
    |> String.replace(~r/&lt;/i, "<")
    |> String.replace(~r/&gt;/i, ">")
    |> String.replace(~r/&#36;/, "$")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s*\n+/, "\n\n")
  end

  defp clean(s) when is_binary(s), do: s |> String.replace_invalid() |> String.trim()

  # Turning on auto-forward makes Gmail mail a confirmation code to the new
  # address. Show it instead of reading it as a bill.
  defp gmail_code(from, subject, text) do
    if address(from) == "forwarding-noreply@google.com" do
      Enum.find_value([subject || "", text], fn s ->
        case Regex.run(~r/\(#(\d{6,12})\)|confirmation code:?\s*(\d{6,12})/i, s) do
          [_, a] -> a
          [_, "", b] -> b
          [_, a, _] -> a
          _ -> nil
        end
      end) || "check your Gmail settings"
    end
  end
end
