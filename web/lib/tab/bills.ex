defmodule Tab.Bills do
  @moduledoc """
  Recurring bills and temporary splits (docs/specification.md, "Phase 3").

  Every function that touches the database takes the current person's
  `%Tab.Accounts.Scope{}` and runs as them, so row-level security decides what
  they can see and change: members manage bills, admins manage temporary
  splits. Logging a bill goes through `Tab.Ledger.create_expense/3` like any
  other expense; this module only works out what to fill in.
  """
  import Ecto.Query
  import Tab.DBError, only: [as_user: 2]
  import Tab.Groups, only: [found: 1, now: 0, set: 3, touched: 1, update: 1]

  alias Tab.Accounts.Scope
  alias Tab.Bills.{Dates, Override, Suggest, Template}
  alias Tab.Repo

  ## Recurring bills

  @doc "The group's live recurring bills, by name."
  def list_templates(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from t in Template,
           where: t.group_id == ^group_id and is_nil(t.deleted_at),
           order_by: fragment("lower(?)", t.name)
       )}
    end)
  end

  def get_template(%Scope{} = scope, id) do
    as_user(scope, fn -> found(Repo.one(from t in Template, where: t.id == ^id)) end)
  end

  def create_template(%Scope{} = scope, group_id, attrs) do
    as_user(scope, fn ->
      with {:ok, t} <- Repo.insert(Template.changeset(%Template{group_id: group_id}, attrs)) do
        {:ok, Repo.get!(Template, t.id)}
      end
    end)
  end

  def update_template(%Scope{} = scope, id, attrs) do
    as_user(scope, fn ->
      with {:ok, t} <- found(Repo.get(Template, id)) do
        t |> Template.changeset(attrs) |> update()
      end
    end)
  end

  @doc "Stops offering a bill. Expenses logged from it stay as they are."
  def delete_template(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Template, id, deleted_at: now())) end)
  end

  @doc """
  What logging `template` fills in: description, amount (the last one), date
  (from `autopay_day`, else today), category, payer, and the period it covers.
  """
  def prefill(%Template{} = t, today \\ Date.utc_today()) do
    date = Dates.autopay_date(t.autopay_day, today)

    %{
      description: t.name,
      amount_cents: t.last_amount_cents,
      date: date,
      category_id: t.category_id,
      paid_by: t.default_payer,
      period: Dates.period(t.cadence, t.cadence_days, date)
    }
  end

  @doc """
  A bill's normal split: its template's default split, or an even split among
  the current members (`member_ids`).
  """
  def normal_split(%Template{default_split: %{} = split}, _member_ids), do: split

  def normal_split(_template, member_ids),
    do: Suggest.equal(Enum.map(member_ids, &{:user, &1}))

  ## Temporary splits

  @doc "The group's live temporary splits, by start date."
  def list_overrides(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from o in Override,
           where: o.group_id == ^group_id and is_nil(o.deleted_at),
           order_by: [o.effective_from, o.inserted_at]
       )}
    end)
  end

  def get_override(%Scope{} = scope, id) do
    as_user(scope, fn -> found(Repo.one(from o in Override, where: o.id == ^id)) end)
  end

  @doc """
  Adds a temporary split (admins only). `{:error, :override_overlap}` when it
  overlaps another on the same bills; see `clashes/3` and `plan_combine/2`.
  """
  def create_override(%Scope{} = scope, group_id, attrs) do
    as_user(scope, fn ->
      with {:ok, o} <- Repo.insert(Override.changeset(%Override{group_id: group_id}, attrs)) do
        {:ok, Repo.get!(Override, o.id)}
      end
    end)
  end

  def update_override(%Scope{} = scope, id, attrs) do
    as_user(scope, fn ->
      with {:ok, o} <- found(Repo.get(Override, id)) do
        o |> Override.changeset(attrs) |> update()
      end
    end)
  end

  def delete_override(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Override, id, deleted_at: now())) end)
  end

  @doc """
  Which of `overrides` a new or changed one would overlap: same bills (no
  category covers every category) and at least one shared day.
  """
  def clashes(overrides, attrs, except_id \\ nil) do
    Enum.filter(overrides, fn o ->
      o.id != except_id and o.deleted_at == nil and
        (o.category_id == nil or attrs.category_id == nil or o.category_id == attrs.category_id) and
        Dates.overlap(
          {o.effective_from, o.effective_until},
          {attrs.effective_from, attrs.effective_until}
        ) != 0
    end)
  end

  @doc """
  How to save `new` (a map with `category_id`, `effective_from`,
  `effective_until`, `split`, `note`) over the live overrides it clashes with,
  so nothing overlaps: each one keeps its days outside `new`, `new` keeps its
  days outside them, and the shared days get `Tab.Bills.Suggest.combine/2`.

  Returns `{:ok, %{pieces: [...], olds: clashes}}` for the admin to confirm, or
  `{:error, :different_bills}` when one covers every category and the other
  one category, or `{:error, :nobody_in_both}` when no one is in both splits.
  Each piece is `%{kind: :new | :old | :both, from:, to:, split:, note:, old:}`.
  """
  def plan_combine(new, clashes) do
    if Enum.any?(clashes, &(&1.category_id != new.category_id)) do
      {:error, :different_bills}
    else
      items = [{:new, new} | Enum.map(clashes, &{:old, &1})]

      bounds =
        items
        |> Enum.flat_map(fn {_, i} ->
          [
            i.effective_from
            | if(i.effective_until, do: [Date.add(i.effective_until, 1)], else: [])
          ]
        end)
        |> Enum.uniq()
        |> Enum.sort(Date)

      ends = bounds |> Enum.drop(1) |> Enum.map(&Date.add(&1, -1))

      Enum.zip(bounds, ends ++ [nil])
      |> Enum.flat_map(fn {from, to} ->
        case owner_at(items, from) do
          nil -> []
          owner -> [{owner, from, to}]
        end
      end)
      |> merge()
      |> Enum.map(&piece(&1, new))
      |> case do
        pieces ->
          if Enum.any?(pieces, &(&1.split == nil)),
            do: {:error, :nobody_in_both},
            else: {:ok, %{pieces: pieces, olds: clashes}}
      end
    end
  end

  defp owner_at(items, date) do
    new? = Enum.any?(items, fn {k, i} -> k == :new and covers?(i, date) end)
    old = Enum.find_value(items, fn {k, i} -> k == :old and covers?(i, date) and i end)

    case {new?, old} do
      {false, nil} -> nil
      {true, nil} -> :new
      {false, o} -> {:old, o}
      {true, o} -> {:both, o}
    end
  end

  defp covers?(i, date) do
    Date.compare(date, i.effective_from) != :lt and
      (i.effective_until == nil or Date.compare(date, i.effective_until) != :gt)
  end

  defp merge(segments) do
    segments
    |> Enum.reduce([], fn
      {owner, from, to}, [{owner, f, t} | rest] when t != nil ->
        if Date.add(t, 1) == from,
          do: [{owner, f, to} | rest],
          else: [{owner, from, to}, {owner, f, t} | rest]

      seg, acc ->
        [seg | acc]
    end)
    |> Enum.reverse()
  end

  defp piece({:new, from, to}, new),
    do: %{kind: :new, from: from, to: to, split: new.split, note: new.note, old: nil}

  defp piece({{:old, o}, from, to}, _new),
    do: %{kind: :old, from: from, to: to, split: o.split, note: o.note, old: o}

  defp piece({{:both, o}, from, to}, new) do
    %{
      kind: :both,
      from: from,
      to: to,
      split: Suggest.combine(new.split, o.split),
      note: join_notes(new.note, o.note),
      old: o
    }
  end

  defp join_notes(a, b) do
    case Enum.reject([a, b], &(&1 in [nil, ""])) do
      [] -> nil
      notes -> Enum.join(notes, " and ")
    end
  end

  @doc """
  Saves a confirmed `plan_combine/2` plan in one transaction: trims or removes
  the old overrides first, then adds the new pieces.
  """
  def apply_plan(%Scope{} = scope, group_id, new, %{pieces: pieces, olds: olds}) do
    kept = fn old -> Enum.filter(pieces, &(&1.kind == :old and &1.old.id == old.id)) end

    as_user(scope, fn ->
      with :ok <- each(olds, &reshape(&1, kept.(&1), group_id)),
           :ok <-
             each(Enum.filter(pieces, &(&1.kind in [:new, :both])), fn p ->
               insert_piece(group_id, new.category_id, p)
             end) do
        {:ok, length(pieces)}
      end
    end)
  end

  defp reshape(old, [], _group_id) do
    with {:ok, :done} <- touched(set(Override, old.id, deleted_at: now())), do: :ok
  end

  defp reshape(old, [first | rest], group_id) do
    with {:ok, current} <- found(Repo.get(Override, old.id)),
         {:ok, _} <-
           current
           |> Override.changeset(%{effective_from: first.from, effective_until: first.to})
           |> update() do
      each(rest, &insert_piece(group_id, old.category_id, &1))
    end
  end

  defp insert_piece(group_id, category_id, p) do
    attrs = %{
      category_id: category_id,
      effective_from: p.from,
      effective_until: p.to,
      split: p.split,
      note: p.note
    }

    case Repo.insert(Override.changeset(%Override{group_id: group_id}, attrs)) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp each(list, fun) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  The split "someone's away" proposes: the category's bill's default split
  without `party`, their share spread over the others by their ratios; or an
  even split among the other current members.
  """
  def away_split(templates, category_id, member_ids, party) do
    template =
      Enum.find(
        templates,
        &(&1.category_id == category_id and category_id != nil and &1.default_split)
      )

    from_template = template && Suggest.without(template.default_split, party)

    from_template ||
      member_ids
      |> Enum.map(&{:user, &1})
      |> Enum.reject(&(&1 == party))
      |> case do
        [] -> nil
        parties -> Suggest.equal(parties)
      end
  end
end
