defmodule Tab.Inbox.Address do
  @moduledoc "A person's forwarding address (`forwarding_addresses`). The random local part is the secret."
  use Tab.Schema

  schema "forwarding_addresses" do
    field :user_id, :binary_id
    field :local_part, :string, redact: true
    field :revoked_at, :utc_datetime

    timestamps()
  end
end
