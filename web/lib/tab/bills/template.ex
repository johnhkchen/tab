defmodule Tab.Bills.Template do
  @moduledoc """
  A bill that comes back (`recurring_templates`). The database keeps
  `last_amount_cents` and `last_logged_on` in step with its newest expense.
  """
  use Tab.Schema

  alias Tab.Ledger.Split

  @cadences ~w(monthly bimonthly quarterly custom_n_days irregular)

  schema "recurring_templates" do
    belongs_to :group, Tab.Groups.Group
    field :name, :string
    belongs_to :category, Tab.Groups.Category
    field :cadence, :string, default: "monthly"
    field :cadence_days, :integer
    field :stability, :string, default: "variable"
    field :default_payer, :binary_id
    field :default_split, :map
    field :autopay_day, :integer
    field :last_amount_cents, :integer
    field :last_logged_on, :date
    # Other names this bill goes by, and the addresses it comes from (phase 4).
    field :aliases, {:array, :string}, default: []
    field :created_by, :binary_id
    field :deleted_at, :utc_datetime

    timestamps()
  end

  def cadences, do: @cadences

  @doc ~S"""
  Aliases tidied: trimmed, blanks and repeats dropped (ignoring case), each
  at most 120 characters, at most 30.

      iex> Tab.Bills.Template.clean_aliases([" SFPUC ", "sfpuc", "", "sfwater.org"])
      ["SFPUC", "sfwater.org"]
  """
  def clean_aliases(nil), do: []

  def clean_aliases(aliases) do
    aliases
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.slice(0, 120)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(30)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :name,
      :category_id,
      :cadence,
      :cadence_days,
      :stability,
      :default_payer,
      :default_split,
      :autopay_day,
      :aliases
    ])
    |> update_change(:aliases, &clean_aliases/1)
    |> validate_required([:name, :cadence, :stability])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_inclusion(:cadence, @cadences)
    |> validate_inclusion(:stability, ~w(fixed variable))
    |> validate_number(:autopay_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
    |> validate_cadence_days()
    |> validate_split()
    |> unique_constraint(:name,
      name: :recurring_templates_unique_name,
      message: "is already a bill in this group"
    )
  end

  defp validate_cadence_days(changeset) do
    if get_field(changeset, :cadence) == "custom_n_days" do
      changeset
      |> validate_required([:cadence_days], message: "say how many days")
      |> validate_number(:cadence_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 366)
    else
      put_change(changeset, :cadence_days, nil)
    end
  end

  defp validate_split(changeset) do
    case get_field(changeset, :default_split) do
      nil ->
        changeset

      %{"type" => type} = split when type in ~w(equal exact percentage shares) ->
        case Split.weights(split, sample_amount(split)) do
          {:ok, _} -> changeset
          {:error, reason} -> add_error(changeset, :default_split, reason)
        end

      _ ->
        add_error(
          changeset,
          :default_split,
          "split it evenly, by exact amounts, percentages, or shares"
        )
    end
  end

  # An exact split is checked against its own total; the others don't need one.
  defp sample_amount(%{"type" => "exact", "entries" => entries}) do
    case Enum.map(entries, & &1["value"]) do
      values when values != [] ->
        if Enum.all?(values, &(is_integer(&1) and &1 >= 0)), do: max(Enum.sum(values), 1), else: 1

      _ ->
        1
    end
  end

  defp sample_amount(_), do: nil
end
