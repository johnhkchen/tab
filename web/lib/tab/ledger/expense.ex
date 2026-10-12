defmodule Tab.Ledger.Expense do
  use Tab.Schema

  schema "expenses" do
    belongs_to :group, Tab.Groups.Group
    field :description, :string
    field :amount_cents, :integer
    field :date, :date
    belongs_to :category, Tab.Groups.Category
    field :paid_by, :binary_id
    field :visibility, :string, default: "shared"
    field :split, :map
    field :period_start, :date
    field :period_end, :date
    field :created_by, :binary_id
    field :deleted_at, :utc_datetime

    has_many :shares, Tab.Ledger.ExpenseShare
    timestamps()
  end

  def changeset(expense, attrs) do
    expense
    |> cast(attrs, [
      :description,
      :amount_cents,
      :date,
      :category_id,
      :paid_by,
      :visibility,
      :split,
      :period_start,
      :period_end
    ])
    |> validate_required([:description, :amount_cents, :date, :paid_by, :split])
    |> update_change(:description, &String.trim/1)
    |> validate_length(:description, min: 1, max: 200)
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_inclusion(:visibility, ~w(shared private))
    |> validate_period()
  end

  defp validate_period(changeset) do
    with %Date{} = from <- get_field(changeset, :period_start),
         %Date{} = to <- get_field(changeset, :period_end),
         :gt <- Date.compare(from, to) do
      add_error(changeset, :period_end, "must be on or after the start")
    else
      _ -> changeset
    end
  end
end
