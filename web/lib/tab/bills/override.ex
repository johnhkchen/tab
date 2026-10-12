defmodule Tab.Bills.Override do
  @moduledoc """
  A temporary split (`split_overrides`): from `effective_from` to
  `effective_until` (no end when `nil`), bills in `category_id` (every category
  when `nil`) are split this way instead. The database refuses overlaps.
  """
  use Tab.Schema

  alias Tab.Ledger.Split

  schema "split_overrides" do
    belongs_to :group, Tab.Groups.Group
    belongs_to :category, Tab.Groups.Category
    field :effective_from, :date
    field :effective_until, :date
    field :split, :map
    field :note, :string
    field :created_by, :binary_id
    field :deleted_at, :utc_datetime

    timestamps()
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:category_id, :effective_from, :effective_until, :split, :note])
    |> validate_required([:effective_from, :split])
    |> update_change(:note, &String.trim/1)
    |> validate_length(:note, max: 200)
    |> validate_dates()
    |> validate_split()
  end

  defp validate_dates(changeset) do
    with %Date{} = from <- get_field(changeset, :effective_from),
         %Date{} = to <- get_field(changeset, :effective_until),
         :gt <- Date.compare(from, to) do
      add_error(changeset, :effective_until, "must be on or after the start")
    else
      _ -> changeset
    end
  end

  defp validate_split(changeset) do
    case get_field(changeset, :split) do
      %{"type" => type} = split when type in ~w(equal percentage shares) ->
        with {:ok, _} <- Split.weights(split),
             {:ok, _} <- Split.compute(split, 1_000_00) do
          changeset
        else
          {:error, reason} -> add_error(changeset, :split, reason)
        end

      nil ->
        changeset

      _ ->
        add_error(changeset, :split, "split it evenly, by percentages, or by shares")
    end
  end
end
