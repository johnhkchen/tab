defmodule Tab.Ledger do
  @moduledoc """
  Expenses, payments, balances, and settle-up suggestions.

  Every function takes the current person's `%Tab.Accounts.Scope{}` and runs as
  them through `Tab.Repo.as_user/2`. The database enforces who may do what,
  stamps who did it, sets payment status, and writes the audit log; this module
  computes splits (`Tab.Ledger.Split`) and turns rows into plain data.

  Parties are `{:user, id}` or `{:counterparty, id}`.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [add_error: 3, get_field: 2]
  import Tab.DBError, only: [as_user: 2]
  import Tab.Groups, only: [found: 1, now: 0, set: 3, touched: 1, update: 1]

  alias Tab.Accounts.Scope
  alias Tab.Ledger.{Expense, Payment, Split}
  alias Tab.Repo

  @deferred "expenses_shares_add_up, expense_shares_add_up"

  ## Expenses

  @doc "The group's expenses this person can see, newest first, with their shares."
  def list_expenses(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from e in Expense,
           where: e.group_id == ^group_id and is_nil(e.deleted_at),
           order_by: [desc: e.date, desc: e.inserted_at],
           preload: :shares
       )}
    end)
  end

  def get_expense(%Scope{} = scope, id) do
    as_user(scope, fn ->
      found(Repo.one(from e in Expense, where: e.id == ^id, preload: :shares))
    end)
  end

  @doc """
  Adds an expense. `attrs` includes `split` (see `Tab.Ledger.Split`); the
  shares are computed here and checked by the database.
  """
  def create_expense(%Scope{} = scope, group_id, attrs) do
    changeset = Expense.changeset(%Expense{group_id: group_id}, attrs)

    with {:ok, shares} <- split(changeset) do
      as_user(scope, fn ->
        with {:ok, expense} <- Repo.insert(changeset) do
          write_shares(expense.id, shares)
        end
      end)
    end
  end

  @doc "Edits an expense and re-splits it. Balances recompute; the edit shows in history."
  def update_expense(%Scope{} = scope, id, attrs) do
    as_user(scope, fn ->
      with {:ok, expense} <- found(Repo.get(Expense, id)),
           changeset = Expense.changeset(expense, attrs),
           {:ok, shares} <- split(changeset),
           {:ok, expense} <- update(changeset) do
        write_shares(expense.id, shares)
      end
    end)
  end

  @doc "Removes an expense from balances. It stays in the history."
  def delete_expense(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Expense, id, deleted_at: now())) end)
  end

  defp split(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp split(changeset) do
    case Split.compute(get_field(changeset, :split), get_field(changeset, :amount_cents)) do
      {:ok, shares} -> {:ok, shares}
      {:error, reason} -> {:error, add_error(changeset, :split, reason)}
    end
  end

  defp write_shares(expense_id, shares) do
    json =
      Enum.map(shares, fn
        {{:user, id}, cents} -> %{"user_id" => id, "amount_cents" => cents}
        {{:counterparty, id}, cents} -> %{"counterparty_id" => id, "amount_cents" => cents}
      end)

    Repo.query!("SELECT set_expense_shares($1, $2)", [Ecto.UUID.dump!(expense_id), json])
    # The add-up check is deferred to commit; run it now so a bad split fails here.
    Repo.query!("SET CONSTRAINTS #{@deferred} IMMEDIATE")
    Repo.query!("SET CONSTRAINTS #{@deferred} DEFERRED")
    {:ok, Repo.one!(from e in Expense, where: e.id == ^expense_id, preload: :shares)}
  end

  ## Payments

  def list_payments(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from p in Payment,
           where: p.group_id == ^group_id and is_nil(p.deleted_at),
           order_by: [desc: p.date, desc: p.inserted_at]
       )}
    end)
  end

  @doc """
  Records a payment. The database sets its status: `pending` between two
  members until the payee confirms, `confirmed` when the payee records it,
  `self_attested` when a counterparty is involved.
  """
  def record_payment(%Scope{} = scope, group_id, attrs) do
    changeset = Payment.changeset(%Payment{group_id: group_id}, attrs)

    as_user(scope, fn ->
      with {:ok, payment} <- Repo.insert(changeset) do
        {:ok, Repo.get!(Payment, payment.id)}
      end
    end)
  end

  @doc "The payee confirms a pending payment."
  def confirm_payment(%Scope{} = scope, id), do: decide(scope, id, "confirmed")

  @doc "The payee declines a pending payment. It never counts."
  def decline_payment(%Scope{} = scope, id), do: decide(scope, id, "declined")

  defp decide(scope, id, status) do
    as_user(scope, fn ->
      with {:ok, :done} <- touched(set(Payment, id, status: status)) do
        {:ok, Repo.get!(Payment, id)}
      end
    end)
  end

  @doc "Whoever recorded a payment edits it. Changing the amount or parties sends it back for confirmation."
  def update_payment(%Scope{} = scope, id, attrs) do
    as_user(scope, fn ->
      with {:ok, payment} <- found(Repo.get(Payment, id)),
           {:ok, payment} <- payment |> Payment.changeset(attrs) |> update() do
        {:ok, Repo.get!(Payment, payment.id)}
      end
    end)
  end

  def delete_payment(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Payment, id, deleted_at: now())) end)
  end

  ## Balances

  @doc """
  Who owes whom in the group, as this person can see it:
  `[%{debtor: party, creditor: party, amount_cents: n}]`.
  """
  def balances(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       "balances"
       |> where([b], b.group_id == type(^group_id, :binary_id))
       |> select([b], %{
         debtor: {b.debtor_kind, type(b.debtor_id, :binary_id)},
         creditor: {b.creditor_kind, type(b.creditor_id, :binary_id)},
         amount_cents: b.amount_cents
       })
       |> Repo.all()
       |> Enum.map(&tag_parties/1)
       |> Enum.sort_by(&{-&1.amount_cents, &1.debtor, &1.creditor})}
    end)
  end

  @doc "Balances per category, netting only payments tagged with that category."
  def category_balances(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       "category_balances"
       |> where([b], b.group_id == type(^group_id, :binary_id))
       |> select([b], %{
         category_id: type(b.category_id, :binary_id),
         debtor: {b.debtor_kind, type(b.debtor_id, :binary_id)},
         creditor: {b.creditor_kind, type(b.creditor_id, :binary_id)},
         amount_cents: b.amount_cents
       })
       |> Repo.all()
       |> Enum.map(&tag_parties/1)
       |> Enum.sort_by(&{&1.category_id, -&1.amount_cents, &1.debtor, &1.creditor})}
    end)
  end

  defp tag_parties(row), do: %{row | debtor: tag(row.debtor), creditor: tag(row.creditor)}
  defp tag({"user", id}), do: {:user, id}
  defp tag({"counterparty", id}), do: {:counterparty, id}

  @doc """
  Suggested payments that would zero out the group: `[%{from:, to:, amount_cents:}]`.
  Read-only; nothing is recorded. Matches the largest debtor with the largest
  creditor each time, which takes at most one fewer payment than there are
  people with a balance.
  """
  def settle_up(%Scope{} = scope, group_id) do
    with {:ok, balances} <- balances(scope, group_id) do
      {:ok, settle(balances)}
    end
  end

  @doc false
  def settle(balances) do
    net =
      Enum.reduce(balances, %{}, fn %{debtor: d, creditor: c, amount_cents: n}, acc ->
        acc |> Map.update(d, -n, &(&1 - n)) |> Map.update(c, n, &(&1 + n))
      end)

    owing = for {party, n} <- net, n < 0, do: {party, -n}
    owed = for {party, n} <- net, n > 0, do: {party, n}
    match(sort(owing), sort(owed), [])
  end

  defp sort(list), do: Enum.sort_by(list, fn {party, n} -> {-n, party} end)

  defp match([], _, acc), do: Enum.reverse(acc)
  defp match(_, [], acc), do: Enum.reverse(acc)

  defp match([{from, a} | owing], [{to, b} | owed], acc) do
    n = min(a, b)
    owing = if a > n, do: sort([{from, a - n} | owing]), else: owing
    owed = if b > n, do: sort([{to, b - n} | owed]), else: owed
    match(owing, owed, [%{from: from, to: to, amount_cents: n} | acc])
  end
end
