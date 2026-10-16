defmodule Tab.OAuth.Connection do
  @moduledoc "One approval: a person let a client use Tab with these scopes."
  use Tab.Schema

  schema "oauth_connections" do
    field :user_id, :binary_id
    belongs_to :client, Tab.OAuth.Client
    field :scopes, {:array, :string}
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    timestamps()
  end
end
