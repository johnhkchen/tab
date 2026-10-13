defmodule Tab.Bills.Dates do
  @moduledoc """
  The dates a recurring bill suggests (docs/specification.md, "Recurring
  templates and one-tap logging"). Pure; every result stays editable.
  """

  @doc """
  The latest `day` of a month on or before `today`. A day past the month's end
  means its last day: 31 in February is the 28th or 29th.

      iex> autopay_date(15, ~D[2026-10-20])
      ~D[2026-10-15]
      iex> autopay_date(25, ~D[2026-10-20])
      ~D[2026-09-25]
      iex> autopay_date(31, ~D[2026-03-05])
      ~D[2026-02-28]
  """
  def autopay_date(nil, today), do: today

  def autopay_date(day, today) when day in 1..31 do
    this_month = clamp(today.year, today.month, day)

    if Date.compare(this_month, today) != :gt do
      this_month
    else
      last = Date.shift(Date.beginning_of_month(today), month: -1)
      clamp(last.year, last.month, day)
    end
  end

  defp clamp(year, month, day) do
    Date.new!(year, month, min(day, Calendar.ISO.days_in_month(year, month)))
  end

  @doc """
  The period a bill dated `date` covers: it ends the day before and reaches back
  one cadence. `nil` for irregular bills.

      iex> period("monthly", nil, ~D[2026-10-03])
      {~D[2026-09-03], ~D[2026-10-02]}
      iex> period("custom_n_days", 10, ~D[2026-10-11])
      {~D[2026-10-01], ~D[2026-10-10]}
  """
  def period(cadence, days, date)
  def period("irregular", _, _), do: nil
  def period(_, _, nil), do: nil

  def period("custom_n_days", n, date) when is_integer(n) and n > 0 do
    finish = Date.add(date, -1)
    {Date.add(finish, 1 - n), finish}
  end

  def period(cadence, _, date) do
    months = %{"monthly" => 1, "bimonthly" => 2, "quarterly" => 3}

    case Map.fetch(months, cadence) do
      {:ok, n} ->
        finish = Date.add(date, -1)
        {finish |> Date.shift(month: -n) |> Date.add(1), finish}

      :error ->
        nil
    end
  end

  @doc """
  When the next bill should have been logged by: one cadence after the last
  one. Nil for `irregular` bills and bills never logged.

      iex> next_due("monthly", nil, ~D[2026-08-31])
      ~D[2026-09-30]
      iex> next_due("custom_n_days", 14, ~D[2026-10-01])
      ~D[2026-10-15]
  """
  def next_due(_, _, nil), do: nil
  def next_due("irregular", _, _), do: nil
  def next_due("custom_n_days", n, last) when is_integer(n), do: Date.add(last, n)

  def next_due(cadence, _, last) do
    case Map.fetch(%{"monthly" => 1, "bimonthly" => 2, "quarterly" => 3}, cadence) do
      {:ok, n} -> Date.shift(last, month: n)
      :error -> nil
    end
  end

  @late_after 7

  @doc """
  Whether a bill is late: nothing logged a week past its next due date. Works
  from what's been logged, so it needs no bill reading.

      iex> late?("monthly", nil, ~D[2026-08-15], ~D[2026-09-22])
      false
      iex> late?("monthly", nil, ~D[2026-08-15], ~D[2026-09-23])
      true
  """
  def late?(cadence, days, last, today) do
    case next_due(cadence, days, last) do
      nil -> false
      due -> Date.diff(today, due) > @late_after
    end
  end

  @doc "Days from `a` to `b`, both included."
  def days({a, b}), do: Date.diff(b, a) + 1

  @doc "How many days two ranges share. `nil` as an end means no end."
  def overlap({a1, b1}, {a2, b2}) do
    from = Enum.max([a1, a2], Date)

    to =
      case {b1, b2} do
        {nil, nil} -> nil
        {nil, b} -> b
        {b, nil} -> b
        {x, y} -> Enum.min([x, y], Date)
      end

    cond do
      to == nil -> :infinity
      Date.compare(from, to) == :gt -> 0
      true -> Date.diff(to, from) + 1
    end
  end
end
