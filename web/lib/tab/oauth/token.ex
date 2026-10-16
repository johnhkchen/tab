defmodule Tab.OAuth.Token do
  @moduledoc "An access or refresh token, stored only as its SHA-256 hash."
  use Tab.Schema

  schema "oauth_tokens" do
    belongs_to :connection, Tab.OAuth.Connection
    belongs_to :code, Tab.OAuth.Code
    field :kind, :string
    field :token_hash, :binary
    field :resource, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    timestamps()
  end
end
