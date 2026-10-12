defmodule Tab.Inbox.Document do
  @moduledoc """
  An original photo, PDF, or email (`documents`). `content` goes to null once
  its item is done with, unless someone kept it with the expense.
  """
  use Tab.Schema

  schema "documents" do
    field :user_id, :binary_id
    field :kind, :string
    field :content_type, :string
    field :filename, :string
    field :byte_size, :integer
    field :sha256, :binary
    field :content, :binary, redact: true
    field :expense_id, :binary_id
    field :purged_at, :utc_datetime

    timestamps()
  end
end
