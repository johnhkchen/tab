defmodule Tab.Reader do
  @moduledoc """
  Asks the `extract/` service to read one document (docs/specification.md,
  "The reader"). It sends the document and gets back proposed fields; it
  never sends anything from the database, and nothing it returns is trusted
  until `Tab.Inbox.Proposal` has checked it and a person has confirmed it.
  """

  @type doc :: %{
          required(:kind) => String.t(),
          required(:content_type) => String.t(),
          required(:content) => binary,
          optional(:subject) => String.t() | nil,
          optional(:from) => String.t() | nil,
          optional(:text) => String.t() | nil
        }

  @doc """
  `{:ok, fields}`, or `{:error, reason}`: `:off` (no API key on the server),
  `:unreadable` (the reader couldn't make sense of it), or `:unreachable`
  (the service is down; worth trying again).
  """
  @spec read(doc) :: {:ok, map} | {:error, :off | :unreadable | :unreachable}
  def read(doc) do
    body = %{
      kind: doc.kind,
      content_type: doc.content_type,
      content: if(doc.kind == "email", do: nil, else: Base.encode64(doc.content)),
      subject: doc[:subject],
      from: doc[:from],
      text: doc[:text]
    }

    options =
      Keyword.merge(
        [
          url: Application.fetch_env!(:tab, :extract_url) <> "/read",
          json: body,
          retry: false,
          receive_timeout: 90_000
        ],
        Application.get_env(:tab, :reader_req, [])
      )

    case Req.post(options) do
      {:ok, %{status: 200, body: %{} = fields}} -> {:ok, fields}
      {:ok, %{status: 503, body: %{"error" => "off"}}} -> {:error, :off}
      {:ok, %{status: status}} when status in 400..499 -> {:error, :unreadable}
      _ -> {:error, :unreachable}
    end
  end
end
