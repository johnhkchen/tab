defmodule Tab.Bills.Forwarder do
  @moduledoc """
  An address that forwards bills for several companies, like a landlord
  (`bill_forwarders`). Mail from it never counts as the company: Tab reads
  the company from the bill itself.
  """
  use Tab.Schema

  schema "bill_forwarders" do
    belongs_to :group, Tab.Groups.Group
    field :address, :string
    field :created_by, :binary_id
    field :deleted_at, :utc_datetime

    timestamps()
  end
end
