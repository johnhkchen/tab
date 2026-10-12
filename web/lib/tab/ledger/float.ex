defmodule Tab.Ledger.Float do
  @moduledoc """
  How long money waits before it comes back (docs/specification.md, "Float").
  Pure: it reads expenses and payments the viewer can already see and returns
  days, never dollars of interest.

  For each pair of parties it walks the money between them by date, expenses
  before payments on the same day. A share opens a lot from whoever owes to
  whoever paid. A payment, or a share owed the other way, closes the oldest
  open lots first; anything left over opens a lot the other way.

  Expenses need `id`, `date`, `paid_by`, `inserted_at`, and `shares` (with
  `user_id` or `counterparty_id`, and `amount_cents`). Payments need `date`,
  `inserted_at`, `amount_cents`, and the four `from_*`/`to_*` party fields;
  pass only ones that count (confirmed or self-attested).
  """

  defmodule Lot do
    @moduledoc false
    # `closed` is [{cents, date}], newest first.
    defstruct [:debtor, :creditor, :cents, :date, :expense_id, :description, closed: []]
  end

  @type party :: {:user, Ecto.UUID.t()} | {:counterparty, Ecto.UUID.t()}

  @doc """
  Walks the ledger. Returns:

    * `:shares` — `%{{expense_id, debtor} => %{days:, open_cents:}}` for every
      share someone owes someone else; `days` is weighted by cents.
    * `:by_creditor` — `%{party => days}`: on average, how long money that
      person paid for others waits.
    * `:open` — `%{{debtor, creditor} => [%{expense_id:, description:, date:, cents:}]}`,
      the shares still unpaid, oldest first.
  """
  def walk(expenses, payments, today \\ Date.utc_today()) do
    lots =
      expenses
      |> events(payments)
      |> Enum.sort_by(& &1.order)
      |> Enum.group_by(&pair_key/1)
      |> Enum.flat_map(fn {_pair, events} -> run(events) end)
      |> Enum.filter(& &1.expense_id)

    shares =
      Map.new(lots, fn lot ->
        {{lot.expense_id, lot.debtor}, %{days: days(lot, today), open_cents: open(lot)}}
      end)

    by_creditor =
      lots
      |> Enum.group_by(& &1.creditor)
      |> Map.new(fn {creditor, lots} -> {creditor, weighted(lots, today)} end)

    open =
      lots
      |> Enum.filter(&(open(&1) > 0))
      |> Enum.sort_by(&{Date.to_gregorian_days(&1.date), &1.expense_id})
      |> Enum.group_by(&{&1.debtor, &1.creditor}, fn lot ->
        %{
          expense_id: lot.expense_id,
          description: lot.description,
          date: lot.date,
          cents: open(lot)
        }
      end)

    %{shares: shares, by_creditor: by_creditor, open: open}
  end

  # Every flow as "debtor owes creditor more": shares owe the payer; a payment
  # from A to B means B owes A back. `order` sorts by date, expenses first.
  defp events(expenses, payments) do
    shares =
      for e <- expenses,
          s <- e.shares,
          debtor = share_party(s),
          debtor != {:user, e.paid_by},
          s.amount_cents > 0 do
        %{
          debtor: debtor,
          creditor: {:user, e.paid_by},
          cents: s.amount_cents,
          date: e.date,
          expense_id: e.id,
          description: e.description,
          order: {Date.to_gregorian_days(e.date), 0, stamp(e.inserted_at), e.id}
        }
      end

    paid =
      for p <- payments do
        %{
          debtor: party(p.to_user_id, p.to_counterparty_id),
          creditor: party(p.from_user_id, p.from_counterparty_id),
          cents: p.amount_cents,
          date: p.date,
          expense_id: nil,
          description: nil,
          order: {Date.to_gregorian_days(p.date), 1, stamp(p.inserted_at), p.id}
        }
      end

    shares ++ paid
  end

  defp stamp(nil), do: 0
  defp stamp(%DateTime{} = t), do: DateTime.to_unix(t, :microsecond)
  defp stamp(%NaiveDateTime{} = t), do: stamp(DateTime.from_naive!(t, "Etc/UTC"))

  defp pair_key(%{debtor: a, creditor: b}), do: Enum.sort([a, b])

  # One pair's events in order; open lots all point one way at any time. A share
  # that cancels debt the other way counts as paid back that same day.
  defp run(events) do
    {open, done} =
      Enum.reduce(events, {[], []}, fn ev, {open, done} ->
        {open, closed, left} =
          case open do
            [%Lot{debtor: d} | _] when d == ev.creditor -> close(open, ev.cents, ev.date, [])
            _ -> {open, [], ev.cents}
          end

        cond do
          ev.expense_id == nil and left == 0 ->
            {open, done ++ closed}

          ev.expense_id == nil ->
            {open ++ [lot(ev, left, [])], done ++ closed}

          left == 0 ->
            {open, done ++ closed ++ [lot(ev, ev.cents, [{ev.cents, ev.date}])]}

          true ->
            settled = if left < ev.cents, do: [{ev.cents - left, ev.date}], else: []
            {open ++ [lot(ev, ev.cents, settled)], done ++ closed}
        end
      end)

    done ++ open
  end

  defp lot(ev, cents, closed) do
    %Lot{
      debtor: ev.debtor,
      creditor: ev.creditor,
      cents: cents,
      date: ev.date,
      expense_id: ev.expense_id,
      description: ev.description,
      closed: closed
    }
  end

  # Closes the oldest lots with `cents` paid on `date`.
  defp close([], cents, _date, closed), do: {[], Enum.reverse(closed), cents}
  defp close(open, 0, _date, closed), do: {open, Enum.reverse(closed), 0}

  defp close([lot | rest], cents, date, closed) do
    remaining = open(lot)
    take = min(remaining, cents)
    lot = %{lot | closed: [{take, date} | lot.closed]}

    if take == remaining,
      do: close(rest, cents - take, date, [lot | closed]),
      else: {[lot | rest], Enum.reverse(closed), 0}
  end

  defp open(%Lot{cents: c, closed: closed}), do: c - Enum.sum(Enum.map(closed, &elem(&1, 0)))

  # Cents-weighted days: closed parts to their repayment date, the open part to today.
  defp days(lot, today) do
    {sum, cents} = parts(lot, today)
    if cents == 0, do: 0, else: round(sum / cents)
  end

  defp weighted(lots, today) do
    {sum, cents} =
      Enum.reduce(lots, {0, 0}, fn lot, {s, c} ->
        {s2, c2} = parts(lot, today)
        {s + s2, c + c2}
      end)

    if cents == 0, do: 0, else: round(sum / cents)
  end

  defp parts(lot, today) do
    pieces = [{open(lot), today} | lot.closed]

    Enum.reduce(pieces, {0, 0}, fn {c, d}, {s, total} ->
      {s + c * max(Date.diff(d, lot.date), 0), total + c}
    end)
  end

  defp share_party(%{user_id: id}) when is_binary(id), do: {:user, id}
  defp share_party(%{counterparty_id: id}), do: {:counterparty, id}

  defp party(user, _cp) when is_binary(user), do: {:user, user}
  defp party(_, cp), do: {:counterparty, cp}
end
