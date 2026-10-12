defmodule Tab.Groups.Category do
  use Tab.Schema

  schema "categories" do
    belongs_to :group, Tab.Groups.Group
    field :name, :string
    field :created_by, :binary_id
    field :deleted_at, :utc_datetime

    timestamps()
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 60)
    |> unique_constraint(:name, name: :categories_unique_name, message: "is already a category")
  end
end
