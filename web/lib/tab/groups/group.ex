defmodule Tab.Groups.Group do
  use Tab.Schema

  schema "groups" do
    field :name, :string
    # Set by the database from auth.uid(); never cast.
    field :created_by, :binary_id
    field :deleted_at, :utc_datetime

    has_many :memberships, Tab.Groups.Membership
    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 120)
  end
end
