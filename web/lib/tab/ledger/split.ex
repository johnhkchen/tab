defmodule Tab.Ledger.Split do
  @moduledoc """
  Turns a split definition and an amount into whole-cent shares. Pure: no
  database, no side effects.

  A split is stored on the expense as JSON (`expenses.split`) in this shape,
  so the expense can be edited and re-split later:

      %{"type" => "equal",      "entries" => [%{"user_id" => a}, %{"counterparty_id" => c}]}
      %{"type" => "exact",      "entries" => [%{"user_id" => a, "value" => 5000}, ...]}
      %{"type" => "percentage", "entries" => [%{"user_id" => a, "value" => "60"}, ...]}
      %{"type" => "shares",     "entries" => [%{"user_id" => a, "value" => 2}, ...]}
      %{"type" => "tiered",     "entries" => [%{"user_id" => a, "value" => 7000}],
                                "rest" => <one of the four above>}

  * `exact` values are cents and must add up to the amount.
  * `percentage` values are numbers or decimal strings with at most two
    decimal places, adding up to 100.
  * `shares` values are positive whole numbers (2:1:1).
  * `tiered` takes fixed cents off the top for the listed people, then splits
    what's left with `rest`. It doesn't nest.

  Rounding (docs/specification.md, "Rounding"): everyone gets the floor of
  their exact share, and the leftover cents go one at a time to the largest
  fractional remainders, ties going to whoever comes first in the split. Shares
  always add up to the amount exactly.
  """

  @type party :: {:user, Ecto.UUID.t()} | {:counterparty, Ecto.UUID.t()}
  @type shares :: [{party, non_neg_integer}]

  @simple ~w(equal exact percentage shares)

  @doc """
  Computes each party's share of `amount_cents`, in the order parties first
  appear in the split.
  """
  @spec compute(map, pos_integer) :: {:ok, shares} | {:error, String.t()}
  def compute(split, amount_cents) when is_integer(amount_cents) and amount_cents > 0 do
    with {:ok, type, entries} <- parse(split) do
      run(type, entries, split, amount_cents)
    end
  end

  def compute(_split, _amount), do: {:error, "the amount must be a positive number of cents"}

  @doc "Like `compute/2` but raises on an invalid split."
  @spec compute!(map, pos_integer) :: shares
  def compute!(split, amount_cents) do
    case compute(split, amount_cents) do
      {:ok, shares} -> shares
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp run("equal", entries, _split, amount) do
    {:ok, by_weight(entries, Enum.map(entries, fn _ -> 1 end), amount)}
  end

  defp run("exact", entries, _split, amount) do
    with {:ok, cents} <- values(entries, &cents/1, "exact amounts") do
      if Enum.sum(cents) == amount,
        do: {:ok, Enum.zip(parties(entries), cents)},
        else: {:error, "exact amounts add up to #{Enum.sum(cents)} cents, not #{amount}"}
    end
  end

  defp run("percentage", entries, _split, amount) do
    with {:ok, hundredths} <- values(entries, &hundredths_of_percent/1, "percentages") do
      if Enum.sum(hundredths) == 10_000,
        do: {:ok, by_weight(entries, hundredths, amount)},
        else:
          {:error, "percentages add up to #{format_hundredths(Enum.sum(hundredths))}, not 100"}
    end
  end

  defp run("shares", entries, _split, amount) do
    with {:ok, weights} <- values(entries, &weight/1, "shares") do
      {:ok, by_weight(entries, weights, amount)}
    end
  end

  defp run("tiered", entries, split, amount) do
    with {:ok, fixed} <- values(entries, &cents/1, "fixed amounts"),
         :ok <- fits(Enum.sum(fixed), amount),
         {:ok, rest} <- rest(split),
         {:ok, rest_shares} <- rest_shares(rest, amount - Enum.sum(fixed)) do
      {:ok, merge(Enum.zip(parties(entries), fixed) ++ rest_shares)}
    end
  end

  defp fits(fixed, amount) when fixed <= amount, do: :ok

  defp fits(fixed, amount),
    do: {:error, "fixed amounts of #{fixed} cents are more than the #{amount} cent total"}

  defp rest(%{"rest" => %{"type" => type} = rest}) when type in @simple, do: {:ok, rest}
  defp rest(%{"rest" => %{"type" => "tiered"}}), do: {:error, "a tiered split can't nest"}
  defp rest(_), do: {:error, "a tiered split needs a rest split"}

  # Nothing left after the fixed amounts: everyone in the rest gets zero.
  defp rest_shares(rest, 0) do
    with {:ok, _type, entries} <- parse(rest), do: {:ok, Enum.map(parties(entries), &{&1, 0})}
  end

  defp rest_shares(rest, remaining), do: compute(rest, remaining)

  # Largest-remainder apportionment over integer weights.
  defp by_weight(entries, weights, amount) do
    total = Enum.sum(weights)

    exact =
      entries
      |> parties()
      |> Enum.zip(weights)
      |> Enum.with_index()
      |> Enum.map(fn {{party, w}, i} ->
        {party, div(amount * w, total), rem(amount * w, total), i}
      end)

    leftover = amount - Enum.sum(Enum.map(exact, &elem(&1, 1)))

    lucky =
      exact
      |> Enum.sort_by(fn {_, _, remainder, i} -> {-remainder, i} end)
      |> Enum.take(leftover)
      |> MapSet.new(fn {_, _, _, i} -> i end)

    Enum.map(exact, fn {party, floor, _, i} ->
      {party, if(MapSet.member?(lucky, i), do: floor + 1, else: floor)}
    end)
  end

  defp merge(shares) do
    {order, totals} =
      Enum.reduce(shares, {[], %{}}, fn {party, cents}, {order, totals} ->
        order = if Map.has_key?(totals, party), do: order, else: [party | order]
        {order, Map.update(totals, party, cents, &(&1 + cents))}
      end)

    order |> Enum.reverse() |> Enum.map(&{&1, Map.fetch!(totals, &1)})
  end

  # -- Parsing -------------------------------------------------------------------

  defp parse(%{"type" => type, "entries" => entries})
       when type in ["tiered" | @simple] and is_list(entries) do
    with {:ok, parties} <- parse_parties(entries) do
      cond do
        type != "tiered" and parties == [] -> {:error, "a split needs at least one person"}
        length(Enum.uniq(parties)) != length(parties) -> {:error, "someone is in the split twice"}
        true -> {:ok, type, entries}
      end
    end
  end

  defp parse(%{"type" => type}) when is_binary(type),
    do: {:error, "unknown split type #{inspect(type)}"}

  defp parse(_), do: {:error, "a split needs a type and entries"}

  defp parse_parties(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case party(entry) do
        {:ok, party} -> {:cont, {:ok, [party | acc]}}
        :error -> {:halt, {:error, "each entry needs a user_id or a counterparty_id"}}
      end
    end)
    |> case do
      {:ok, parties} -> {:ok, Enum.reverse(parties)}
      error -> error
    end
  end

  defp party(%{"user_id" => id} = entry)
       when is_binary(id) and not is_map_key(entry, "counterparty_id"),
       do: {:ok, {:user, id}}

  defp party(%{"counterparty_id" => id} = entry)
       when is_binary(id) and not is_map_key(entry, "user_id"),
       do: {:ok, {:counterparty, id}}

  defp party(_), do: :error

  defp parties(entries), do: Enum.map(entries, fn e -> elem(party(e), 1) end)

  defp values(entries, fun, label) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case fun.(Map.get(entry, "value")) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :error -> {:halt, {:error, "#{label} must be #{describe(label)}"}}
      end
    end)
    |> case do
      {:ok, vs} -> {:ok, Enum.reverse(vs)}
      error -> error
    end
  end

  defp describe("shares"), do: "positive whole numbers"
  defp describe("percentages"), do: "between 0 and 100, with at most two decimal places"
  defp describe(_), do: "whole cents, zero or more"

  defp cents(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp cents(_), do: :error

  defp weight(v) when is_integer(v) and v > 0, do: {:ok, v}
  defp weight(_), do: :error

  defp hundredths_of_percent(v) when is_integer(v), do: hundredths_of_percent(Decimal.new(v))
  defp hundredths_of_percent(v) when is_float(v), do: hundredths_of_percent(Decimal.from_float(v))

  defp hundredths_of_percent(v) when is_binary(v) do
    case Decimal.parse(v) do
      {d, ""} -> hundredths_of_percent(d)
      _ -> :error
    end
  end

  defp hundredths_of_percent(%Decimal{} = d) do
    h = Decimal.mult(d, 100)

    if Decimal.integer?(h) and not Decimal.negative?(h) and Decimal.compare(d, 100) != :gt,
      do: {:ok, Decimal.to_integer(h)},
      else: :error
  end

  defp hundredths_of_percent(_), do: :error

  defp format_hundredths(h),
    do:
      h |> Decimal.new() |> Decimal.div(100) |> Decimal.normalize() |> Decimal.to_string(:normal)
end
