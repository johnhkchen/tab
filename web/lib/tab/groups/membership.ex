defmodule Tab.Groups.Membership do
  use Tab.Schema

  schema "memberships" do
    belongs_to :group, Tab.Groups.Group
    field :user_id, :binary_id
    field :role, :string, default: "member"
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime

    belongs_to :profile, Tab.Accounts.Profile,
      foreign_key: :user_id,
      references: :user_id,
      define_field: false

    timestamps()
  end
end
