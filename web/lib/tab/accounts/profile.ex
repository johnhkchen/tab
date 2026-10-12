defmodule Tab.Accounts.Profile do
  @moduledoc """
  What people who share a group with you can see: your display name and how to
  pay you. Made by the database when the user is; never inserted by the app.
  """
  use Tab.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  schema "profiles" do
    field :display_name, :string
    field :payment_methods, {:array, :map}, default: []
    field :reminder_channel, :string, default: "email"

    timestamps()
  end

  @kinds ~w(venmo zelle cashapp paypal cash check other)

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:display_name, :payment_methods])
    |> validate_required([:display_name])
    |> update_change(:display_name, &String.trim/1)
    |> validate_length(:display_name, min: 1, max: 80)
    |> validate_change(:payment_methods, fn :payment_methods, methods ->
      if Enum.all?(methods, &(&1["kind"] in @kinds and is_binary(&1["handle"]))),
        do: [],
        else: [payment_methods: "each needs a known kind and a handle"]
    end)
  end
end
