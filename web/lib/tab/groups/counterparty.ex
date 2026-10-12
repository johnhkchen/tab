defmodule Tab.Groups.Counterparty do
  @moduledoc "An outside party in a group's money: a landlord, a utility, the household next door. Not an account."
  use Tab.Schema

  schema "counterparties" do
    belongs_to :group, Tab.Groups.Group
    field :name, :string
    field :contact_email, :string
    field :notes, :string
    field :created_by, :binary_id
    field :deleted_at, :utc_datetime

    timestamps()
  end

  def changeset(counterparty, attrs) do
    counterparty
    |> cast(attrs, [:name, :contact_email, :notes])
    |> validate_required([:name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:contact_email, max: 254)
    |> validate_length(:notes, max: 2000)
  end
end
