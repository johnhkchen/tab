defmodule TabWeb.DocumentController do
  @moduledoc """
  An original bill: a photo, a PDF, or an email, shown to whoever the database
  lets see it (its owner, or the group of the expense it was kept with).
  Served sandboxed, so nothing inside it can run as Tab.
  """
  use TabWeb, :controller

  alias Tab.Inbox

  def show(conn, %{"id" => id} = params) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, doc} <- Inbox.content(conn.assigns.current_scope, id),
         {:ok, doc} <- pick(doc, params["part"]) do
      conn
      |> put_resp_content_type(type(doc), nil)
      |> csp(doc)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-disposition", ~s(inline; filename="#{filename(doc)}"))
      |> send_resp(200, doc.content)
    else
      _ -> conn |> put_status(404) |> put_view(TabWeb.ErrorHTML) |> render(:"404")
    end
  end

  # `?part=attachment` serves the PDF or image inside a forwarded email.
  defp pick(%{kind: "email"} = doc, "attachment") do
    with {:ok, %{part: {kind, type, name, data}}} <- Tab.Inbox.Email.parse(doc.content),
         true <- Inbox.looks_like?(type, data) do
      {:ok, %{doc | kind: to_string(kind), content_type: type, filename: name, content: data}}
    else
      _ -> :error
    end
  end

  defp pick(doc, nil), do: {:ok, doc}
  defp pick(_, _), do: :error

  # Browsers' PDF viewers won't run in a sandbox; a PDF was checked to be one
  # at upload, and the viewer keeps its scripts away from the page.
  defp csp(conn, %{kind: "pdf"}),
    do: put_resp_header(conn, "content-security-policy", "default-src 'none'; object-src 'self'")

  defp csp(conn, _),
    do:
      put_resp_header(
        conn,
        "content-security-policy",
        "sandbox; default-src 'none'; img-src 'self' data:"
      )

  # An email shows as text: its HTML could carry anything.
  defp type(%{kind: "email"}), do: "text/plain; charset=utf-8"
  defp type(%{content_type: type}), do: type

  defp filename(%{filename: name, kind: kind}) when is_binary(name),
    do: String.replace(name, ~r/[^\w.\- ]/u, "_") |> ensure_ext(kind)

  defp filename(%{kind: "pdf"}), do: "bill.pdf"
  defp filename(%{kind: "email"}), do: "email.txt"
  defp filename(_), do: "bill.jpg"

  defp ensure_ext(name, "email"), do: name <> ".txt"
  defp ensure_ext(name, _), do: name
end
