defmodule Tab.Inbox.Item do
  @moduledoc """
  A bill waiting for its person to check it (`pending_items`), with every
  document that arrived about it. `proposal` is what the reader returned,
  after `Tab.Inbox.Proposal` checked it, merged across those documents; it
  becomes nothing until someone saves the expense.
  """
  use Tab.Schema

  schema "pending_items" do
    field :user_id, :binary_id
    field :source, :string
    field :status, :string, default: "reading"
    field :doc_type, :string
    field :proposal, :map, default: %{}
    field :due_on, :date
    field :template_id, :binary_id
    field :group_id, :binary_id
    field :expense_id, :binary_id
    field :duplicate_of, :binary_id
    field :note, :string
    field :read_at, :utc_datetime

    has_many :documents, Tab.Inbox.Document, preload_order: [asc: :inserted_at]

    timestamps()
  end
end
