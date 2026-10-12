defmodule Tab.Inbox.Message do
  @moduledoc """
  One email Resend received for Tab (`inbound_messages`). Written by the
  webhook as the connection owner; the person it was for can read it.
  """
  use Tab.Schema

  schema "inbound_messages" do
    field :provider, :string, default: "resend"
    field :provider_id, :string
    field :user_id, :binary_id
    field :status, :string, default: "fetching"
    field :kind, :string, default: "bill"
    field :detail, :string
    field :from_address, :string
    field :subject, :string
    field :received_at, :utc_datetime

    timestamps()
  end
end
