defmodule Tab.OAuth.Client do
  @moduledoc """
  An app that asked to connect: Claude Code, claude.ai, or another MCP client.
  `client_id` is the URL of its metadata document (CIMD) or an id Tab handed
  out when it registered itself (DCR).
  """
  use Tab.Schema

  schema "oauth_clients" do
    field :client_id, :string
    field :kind, :string
    field :name, :string
    field :redirect_uris, {:array, :string}
    field :fetched_at, :utc_datetime
    field :fresh_until, :utc_datetime
    timestamps()
  end
end
