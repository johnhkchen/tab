defmodule Tab.Ledger.ExpenseShare do
  @moduledoc "One person's (or counterparty's) part of an expense. Written only by `set_expense_shares`."
  use Tab.Schema

  schema "expense_shares" do
    belongs_to :expense, Tab.Ledger.Expense
    field :group_id, :binary_id
    field :user_id, :binary_id
    field :counterparty_id, :binary_id
    field :amount_cents, :integer

    timestamps(updated_at: false)
  end
end
