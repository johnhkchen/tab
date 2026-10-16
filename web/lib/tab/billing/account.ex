defmodule Tab.Billing.Account do
  @moduledoc "A person's plan on Hosted Tab. Plans are worked out from these dates (`Tab.Billing.plan/2`)."
  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "billing_accounts" do
    field :paid_plan, :string
    field :paid_until, :utc_datetime
    field :paddle_customer_id, :string
    field :paddle_subscription_id, :string
    field :subscription_status, :string
    field :subscription_event_at, :utc_datetime_usec
    field :trial_until, :utc_datetime
    field :warned_month, :date
    timestamps()
  end
end
