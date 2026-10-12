defmodule Tab.Groups.Invite do
  use Tab.Schema

  schema "invites" do
    belongs_to :group, Tab.Groups.Group
    field :token_hash, :binary, redact: true
    field :created_by, :binary_id
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :used_by, :binary_id
    field :revoked_at, :utc_datetime

    timestamps()
  end
end
