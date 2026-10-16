defmodule Tab.OAuth.Code do
  @moduledoc "An authorization code: one minute, one use, bound to a PKCE challenge."
  use Tab.Schema

  schema "oauth_codes" do
    belongs_to :connection, Tab.OAuth.Connection
    field :code_hash, :binary
    field :redirect_uri, :string
    field :code_challenge, :string
    field :resource, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    timestamps()
  end
end
