defmodule Tab.Ledger.Payment do
  use Tab.Schema

  @methods ~w(venmo zelle cashapp paypal cash check other)

  schema "payments" do
    belongs_to :group, Tab.Groups.Group
    field :from_user_id, :binary_id
    field :from_counterparty_id, :binary_id
    field :to_user_id, :binary_id
    field :to_counterparty_id, :binary_id
    field :amount_cents, :integer
    field :date, :date
    belongs_to :category, Tab.Groups.Category
    field :method, :string
    field :reference, :string
    # Set by the database from the parties; never cast.
    field :status, :string
    field :recorded_by, :binary_id
    field :confirmed_at, :utc_datetime
    field :confirmed_by, :binary_id
    field :deleted_at, :utc_datetime

    timestamps()
  end

  def methods, do: @methods

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :from_user_id,
      :from_counterparty_id,
      :to_user_id,
      :to_counterparty_id,
      :amount_cents,
      :date,
      :category_id,
      :method,
      :reference
    ])
    |> validate_required([:amount_cents, :date, :method])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_inclusion(:method, @methods)
    |> validate_length(:reference, max: 200)
    |> validate_one_of(:from, [:from_user_id, :from_counterparty_id])
    |> validate_one_of(:to, [:to_user_id, :to_counterparty_id])
    |> validate_not_self()
  end

  defp validate_one_of(changeset, side, [user, counterparty]) do
    case {get_field(changeset, user), get_field(changeset, counterparty)} do
      {nil, nil} -> add_error(changeset, user, "pick who the money went #{side}")
      {_, nil} -> changeset
      {nil, _} -> changeset
      _ -> add_error(changeset, user, "pick one person or counterparty")
    end
  end

  defp validate_not_self(changeset) do
    from = get_field(changeset, :from_user_id)

    if from && from == get_field(changeset, :to_user_id),
      do: add_error(changeset, :to_user_id, "can't be the same person who paid"),
      else: changeset
  end
end
