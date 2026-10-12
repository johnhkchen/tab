defmodule Tab.Statements.Link do
  @moduledoc "A statement link for one person and one month (`statement_links`). Only its hash is stored."
  use Tab.Schema

  schema "statement_links" do
    belongs_to :group, Tab.Groups.Group
    field :token_hash, :binary, redact: true
    field :user_id, :binary_id
    field :counterparty_id, :binary_id
    field :period_start, :date
    field :period_end, :date
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :created_by, :binary_id

    timestamps()
  end
end
