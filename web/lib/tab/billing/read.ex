defmodule Tab.Billing.Read do
  @moduledoc "One document sent to the reader on Hosted Tab, counted against the month's allowance."
  use Tab.Schema

  schema "reads" do
    field :user_id, :binary_id
    field :document_id, :binary_id
    field :paid, :boolean
    field :read_on, :date
    field :inserted_at, :utc_datetime
  end
end
