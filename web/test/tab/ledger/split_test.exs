defmodule Tab.Ledger.SplitTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tab.Ledger.Split

  @a "00000000-0000-4000-8000-00000000000a"
  @b "00000000-0000-4000-8000-00000000000b"
  @c "00000000-0000-4000-8000-00000000000c"
  @landlord "00000000-0000-4000-8000-0000000000cc"

  defp u(id, value \\ nil), do: entry(%{"user_id" => id}, value)
  defp cp(id, value \\ nil), do: entry(%{"counterparty_id" => id}, value)
  defp entry(e, nil), do: e
  defp entry(e, value), do: Map.put(e, "value", value)

  defp cents(shares), do: Enum.map(shares, &elem(&1, 1))

  describe "the spec's examples" do
    test "equal: $90 among three is 30/30/30" do
      split = %{"type" => "equal", "entries" => [u(@a), u(@b), u(@c)]}

      assert Split.compute!(split, 9_000) == [
               {{:user, @a}, 3_000},
               {{:user, @b}, 3_000},
               {{:user, @c}, 3_000}
             ]
    end

    test "equal: $100 among three gives the spare cent to whoever's first" do
      split = %{"type" => "equal", "entries" => [u(@a), u(@b), u(@c)]}
      assert cents(Split.compute!(split, 10_000)) == [3_334, 3_333, 3_333]
    end

    test "exact: A $50, B $40" do
      split = %{"type" => "exact", "entries" => [u(@a, 5_000), u(@b, 4_000)]}
      assert cents(Split.compute!(split, 9_000)) == [5_000, 4_000]
    end

    test "percentage: 60/40, with decimals" do
      split = %{"type" => "percentage", "entries" => [u(@a, 60), u(@b, "40")]}
      assert cents(Split.compute!(split, 10_001)) == [6_001, 4_000]

      thirds = %{
        "type" => "percentage",
        "entries" => [u(@a, "33.33"), u(@b, 33.33), u(@c, "33.34")]
      }

      assert cents(Split.compute!(thirds, 10_000)) == [3_333, 3_333, 3_334]
    end

    test "shares: 2:1:1" do
      split = %{"type" => "shares", "entries" => [u(@a, 2), u(@b, 1), u(@c, 1)]}
      assert cents(Split.compute!(split, 10_000)) == [5_000, 2_500, 2_500]
    end

    test "tiered: $70 to A first, then 60/40 of the rest" do
      split = %{
        "type" => "tiered",
        "entries" => [u(@a, 7_000)],
        "rest" => %{"type" => "percentage", "entries" => [u(@a, 60), u(@b, 40)]}
      }

      assert Split.compute!(split, 17_000) == [{{:user, @a}, 13_000}, {{:user, @b}, 4_000}]
    end

    test "counterparties can be in a split" do
      split = %{"type" => "equal", "entries" => [u(@a), cp(@landlord)]}

      assert Split.compute!(split, 1_000) == [
               {{:user, @a}, 500},
               {{:counterparty, @landlord}, 500}
             ]
    end
  end

  describe "refuses" do
    test "exact amounts that don't add up" do
      split = %{"type" => "exact", "entries" => [u(@a, 5_000), u(@b, 3_000)]}

      assert {:error, "exact amounts add up to 8000 cents, not 9000"} =
               Split.compute(split, 9_000)
    end

    test "percentages that don't add up to 100, or with too many decimals" do
      assert {:error, "percentages add up to 90, not 100"} =
               Split.compute(%{"type" => "percentage", "entries" => [u(@a, 50), u(@b, 40)]}, 100)

      assert {:error, _} =
               Split.compute(
                 %{"type" => "percentage", "entries" => [u(@a, "99.995"), u(@b, "0.005")]},
                 100
               )

      assert {:error, _} =
               Split.compute(
                 %{"type" => "percentage", "entries" => [u(@a, -10), u(@b, 110)]},
                 100
               )
    end

    test "zero or fractional shares" do
      assert {:error, _} =
               Split.compute(%{"type" => "shares", "entries" => [u(@a, 0), u(@b, 1)]}, 100)

      assert {:error, _} =
               Split.compute(%{"type" => "shares", "entries" => [u(@a, 1.5), u(@b, 1)]}, 100)
    end

    test "someone in the split twice, or nobody at all" do
      assert {:error, "someone is in the split twice"} =
               Split.compute(%{"type" => "equal", "entries" => [u(@a), u(@a)]}, 100)

      assert {:error, _} = Split.compute(%{"type" => "equal", "entries" => []}, 100)
    end

    test "entries that name both or neither kind of party" do
      assert {:error, _} =
               Split.compute(
                 %{"type" => "equal", "entries" => [%{"user_id" => @a, "counterparty_id" => @b}]},
                 100
               )

      assert {:error, _} =
               Split.compute(%{"type" => "equal", "entries" => [%{"name" => "A"}]}, 100)
    end

    test "fixed amounts over the total, nested tiers, and a missing rest" do
      rest = %{"type" => "equal", "entries" => [u(@b)]}

      assert {:error, _} =
               Split.compute(
                 %{"type" => "tiered", "entries" => [u(@a, 200)], "rest" => rest},
                 100
               )

      nested = %{"type" => "tiered", "entries" => [], "rest" => rest}

      assert {:error, "a tiered split can't nest"} =
               Split.compute(
                 %{"type" => "tiered", "entries" => [u(@a, 10)], "rest" => nested},
                 100
               )

      assert {:error, _} = Split.compute(%{"type" => "tiered", "entries" => [u(@a, 10)]}, 100)
    end

    test "unknown types and non-positive amounts" do
      assert {:error, _} = Split.compute(%{"type" => "formula", "entries" => [u(@a)]}, 100)
      assert {:error, _} = Split.compute(%{"type" => "equal", "entries" => [u(@a)]}, 0)
    end
  end

  # -- Properties ------------------------------------------------------------------

  defp parties(n),
    do:
      Enum.map(1..n//1, fn i ->
        "00000000-0000-4000-8000-#{String.pad_leading("#{i}", 12, "0")}"
      end)

  defp amount, do: integer(1..10_000_000)

  defp simple_split(types \\ ~w(equal percentage shares exact)) do
    gen all(
          n <- integer(1..12),
          type <- member_of(types),
          weights <- list_of(integer(1..50), length: n),
          total <- amount()
        ) do
      ids = parties(n)

      entries =
        case type do
          "equal" ->
            Enum.map(ids, &u/1)

          "shares" ->
            Enum.zip_with(ids, weights, &u/2)

          "percentage" ->
            Enum.zip_with(ids, to_hundredths(weights), &u(&1, Decimal.to_string(&2)))

          "exact" ->
            Enum.zip_with(ids, apportion(total, weights), &u/2)
        end

      {%{"type" => type, "entries" => entries}, total, weights}
    end
  end

  # Weights scaled to percentages that add up to exactly 100.00.
  defp to_hundredths(weights) do
    apportion(10_000, weights) |> Enum.map(&Decimal.div(Decimal.new(&1), 100))
  end

  defp apportion(total, weights) do
    sum = Enum.sum(weights)
    floors = Enum.map(weights, &div(total * &1, sum))
    [first | rest] = floors
    [first + total - Enum.sum(floors) | rest]
  end

  property "shares always add up to the amount, and none is negative" do
    check all({split, total, _} <- simple_split()) do
      shares = cents(Split.compute!(split, total))
      assert Enum.sum(shares) == total
      assert Enum.all?(shares, &(&1 >= 0))
    end
  end

  property "equal shares differ by at most one cent" do
    check all(n <- integer(1..30), total <- amount()) do
      shares =
        cents(
          Split.compute!(%{"type" => "equal", "entries" => Enum.map(parties(n), &u/1)}, total)
        )

      assert Enum.max(shares) - Enum.min(shares) <= 1
    end
  end

  property "weighted shares are within one cent of the exact proportion" do
    check all(
            n <- integer(1..12),
            weights <- list_of(integer(1..50), length: n),
            total <- amount()
          ) do
      split = %{"type" => "shares", "entries" => Enum.zip_with(parties(n), weights, &u/2)}
      sum = Enum.sum(weights)

      for {share, w} <- Enum.zip(cents(Split.compute!(split, total)), weights) do
        assert abs(share * sum - total * w) < sum
      end
    end
  end

  property "tiered gives the fixed amounts first and splits the rest" do
    check all(
            {rest, _, _} <- simple_split(~w(equal percentage shares)),
            fixed_count <- integer(0..4),
            fixed <- list_of(integer(0..50_000), length: fixed_count),
            extra <- integer(1..1_000_000)
          ) do
      fixed_entries = Enum.zip_with(parties(fixed_count), fixed, &u/2)
      total = Enum.sum(fixed) + extra
      split = %{"type" => "tiered", "entries" => fixed_entries, "rest" => rest}

      shares = Map.new(Split.compute!(split, total))
      rest_shares = Map.new(Split.compute!(rest, extra))

      assert Enum.sum(Map.values(shares)) == total

      for {party, cents} <- shares do
        fixed_part =
          Enum.find_value(fixed_entries, 0, fn e ->
            {:user, e["user_id"]} == party && e["value"]
          end)

        assert cents == fixed_part + Map.get(rest_shares, party, 0)
      end
    end
  end

  property "the same split always gives the same shares" do
    check all({split, total, _} <- simple_split()) do
      assert Split.compute!(split, total) == Split.compute!(split, total)
    end
  end
end
