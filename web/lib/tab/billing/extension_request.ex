defmodule Tab.Billing.ExtensionRequest do
  @moduledoc "Someone asking for 6 more months of trial Plus, with their answer to one question."
  use Tab.Schema

  schema "extension_requests" do
    field :user_id, :binary_id
    field :question, :string
    field :answer, :string
    field :may_quote, :boolean, default: false
    field :status, :string, default: "waiting"
    field :decided_at, :utc_datetime
    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> Ecto.Changeset.cast(attrs, [:answer, :may_quote])
    |> Ecto.Changeset.validate_required([:answer])
    |> Ecto.Changeset.update_change(:answer, &String.trim/1)
    |> Ecto.Changeset.validate_length(:answer, min: 1, max: 2000)
  end
end
