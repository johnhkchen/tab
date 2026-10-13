defmodule Tab.Inbox.Document do
  @moduledoc """
  One thing that arrived about a bill (`documents`): a photo, a PDF, or an
  email. `content` is the original and goes to null once its bill is saved
  or dropped. What stays is a reference: what it was (`role`), who sent it,
  the subject, when, the amount, and a `search` line for finding it again in
  the mailbox it came from.
  """
  use Tab.Schema

  @roles ~w(bill notice autopay_scheduled payment reminder other)

  schema "documents" do
    field :user_id, :binary_id
    belongs_to :item, Tab.Inbox.Item
    field :kind, :string
    field :content_type, :string
    field :filename, :string
    field :byte_size, :integer
    field :sha256, :binary
    field :fingerprint, :binary
    field :content, :binary, redact: true
    field :role, :string
    field :sender, :string
    field :subject, :string
    field :sent_at, :naive_datetime
    field :amount_cents, :integer
    field :search, :string
    field :reading, :map
    field :expense_id, :binary_id
    field :purged_at, :utc_datetime

    timestamps()
  end

  def roles, do: @roles
end
