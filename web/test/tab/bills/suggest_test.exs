defmodule Tab.Bills.SuggestTest do
  @moduledoc """
  Phase 3 test 4, the pure half: which split the form suggests, day-based
  proration, combining overlapping temporary splits, and the combine plan.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tab.Bills
  alias Tab.Bills.{Dates, Suggest}
  alias Tab.Ledger.Split

  doctest Tab.Bills.Dates, import: true

  @p {:user, "p"}
  @a {:user, "a"}
  @s {:user, "s"}
  @j {:user, "j"}
  @everyone Suggest.equal([@p, @a, @s, @j])
  @without_alex Suggest.equal([@p, @s, @j])
  @without_sam Suggest.equal([@p, @a, @j])

  defp override(from, until, split, category \\ "utilities", note \\ nil) do
    %{
      id: make_ref(),
      category_id: category,
      effective_from: from,
      effective_until: until,
      split: split,
      note: note,
      deleted_at: nil
    }
  end

  defp alex_away,
    do: override(~D[2026-11-01], ~D[2026-11-30], @without_alex, "utilities", "Alex away")

  defp cents(split, amount), do: split |> Split.compute!(amount) |> Map.new()

  describe "Alex away from utilities, Nov 1 to 30" do
    test "applies to utilities bills dated inside the window" do
      {split, why} =
        Suggest.suggest(@everyone, [alex_away()], %{
          category_id: "utilities",
          date: ~D[2026-11-10]
        })

      assert split == @without_alex
      assert {:override, %{note: "Alex away"}} = why
    end

    test "leaves rent alone" do
      assert {@everyone, nil} =
               Suggest.suggest(@everyone, [alex_away()], %{
                 category_id: "rent",
                 date: ~D[2026-11-10]
               })
    end

    test "stops on its own after Nov 30" do
      assert {@everyone, nil} =
               Suggest.suggest(@everyone, [alex_away()], %{
                 category_id: "utilities",
                 date: ~D[2026-12-01]
               })
    end

    test "an override with no category covers every category" do
      everything = override(~D[2026-11-01], nil, @without_alex, nil)

      assert {@without_alex, _} =
               Suggest.suggest(@everyone, [everything], %{
                 category_id: "rent",
                 date: ~D[2027-03-01]
               })
    end
  end

  describe "proration against each bill's own period" do
    # Alex is away 48 days, Nov 10 to Dec 27, over two monthly electric bills.
    setup do
      %{away: override(~D[2026-11-10], ~D[2026-12-27], @without_alex)}
    end

    test "the first bill overlaps 5 of its 31 days", %{away: away} do
      {split, {:prorated, [{_, 5}], 31}} =
        Suggest.suggest(@everyone, [away], %{
          category_id: "utilities",
          date: ~D[2026-11-15],
          period: {~D[2026-10-15], ~D[2026-11-14]},
          amount_cents: 18_600
        })

      # Alex: 1/4 for 26 days; the others: 1/4 for 26 days plus 1/3 for 5.
      assert split["type"] == "shares"
      shares = cents(split, 18_600)
      assert shares[@a] == 3_900
      assert shares[@p] == 4_900
      assert Enum.sum(Map.values(shares)) == 18_600
    end

    test "the second bill falls entirely inside, with no change to the override", %{away: away} do
      assert {@without_alex, {:override, ^away}} =
               Suggest.suggest(@everyone, [away], %{
                 category_id: "utilities",
                 date: ~D[2026-12-15],
                 period: {~D[2026-11-15], ~D[2026-12-14]},
                 amount_cents: 9_000
               })
    end

    test "an exact normal split blends in cents of this bill" do
      rent = %{
        "type" => "exact",
        "entries" => [
          %{"user_id" => "p", "value" => 6_000},
          %{"user_id" => "a", "value" => 4_000}
        ]
      }

      away = override(~D[2026-11-16], ~D[2026-11-30], Suggest.equal([@p]))

      {split, _} =
        Suggest.suggest(rent, [away], %{
          category_id: "utilities",
          date: ~D[2026-12-01],
          period: {~D[2026-11-01], ~D[2026-11-30]},
          amount_cents: 10_000
        })

      assert cents(split, 10_000) == %{@p => 8_000, @a => 2_000}
    end

    test "without an amount, an exact normal split isn't blended yet" do
      rent = %{"type" => "exact", "entries" => [%{"user_id" => "p", "value" => 6_000}]}
      away = override(~D[2026-11-16], ~D[2026-11-30], Suggest.equal([@p]))

      assert {^rent, nil} =
               Suggest.suggest(rent, [away], %{
                 category_id: "utilities",
                 period: {~D[2026-11-01], ~D[2026-11-30]}
               })
    end

    property "suggested shares always add up, zero days gives the normal split, all days the override" do
      check all(
              start <- integer(0..400),
              length <- integer(1..120),
              away_start <- integer(0..520),
              away_length <- integer(1..120),
              amount <- integer(1..10_000_000)
            ) do
        base = ~D[2026-01-01]
        period = {Date.add(base, start), Date.add(base, start + length - 1)}

        away =
          override(
            Date.add(base, away_start),
            Date.add(base, away_start + away_length - 1),
            @without_alex
          )

        {split, _} =
          Suggest.suggest(@everyone, [away], %{
            category_id: "utilities",
            period: period,
            amount_cents: amount
          })

        assert {:ok, shares} = Split.compute(split, amount)
        assert shares |> Enum.map(&elem(&1, 1)) |> Enum.sum() == amount

        case Dates.overlap(period, {away.effective_from, away.effective_until}) do
          0 -> assert split == @everyone
          ^length -> assert split == @without_alex
          _ -> assert split["type"] == "shares"
        end
      end
    end
  end

  describe "combining overlaps" do
    test "anyone left out of either stays out" do
      assert %{"type" => "shares", "entries" => entries} =
               Suggest.combine(@without_alex, @without_sam)

      assert Enum.map(entries, & &1["user_id"]) == ["p", "j"]
      assert Enum.map(entries, & &1["value"]) == [1, 1]
    end

    test "nobody in both gives no suggestion" do
      assert Suggest.combine(Suggest.equal([@a]), Suggest.equal([@s])) == nil
    end

    test "the plan trims the old one and adds the new days and the shared days" do
      old = alex_away()
      new = override(~D[2026-11-15], ~D[2026-12-15], @without_sam, "utilities", "Sam away")

      assert {:ok, %{pieces: pieces}} = Bills.plan_combine(new, [old])

      assert Enum.map(pieces, &{&1.kind, &1.from, &1.to}) == [
               {:old, ~D[2026-11-01], ~D[2026-11-14]},
               {:both, ~D[2026-11-15], ~D[2026-11-30]},
               {:new, ~D[2026-12-01], ~D[2026-12-15]}
             ]

      both = Enum.find(pieces, &(&1.kind == :both))
      assert both.note == "Sam away and Alex away"
      assert both.split == Suggest.combine(@without_sam, @without_alex)
    end

    test "a new one inside an old one splits the old one in two" do
      old = override(~D[2026-11-01], nil, @without_alex)
      new = override(~D[2026-11-10], ~D[2026-11-20], @without_sam)

      assert {:ok, %{pieces: pieces}} = Bills.plan_combine(new, [old])

      assert Enum.map(pieces, &{&1.kind, &1.from, &1.to}) == [
               {:old, ~D[2026-11-01], ~D[2026-11-09]},
               {:both, ~D[2026-11-10], ~D[2026-11-20]},
               {:old, ~D[2026-11-21], nil}
             ]
    end

    test "every category against one category can't be combined" do
      assert {:error, :different_bills} =
               Bills.plan_combine(override(~D[2026-11-10], nil, @without_sam, nil), [alex_away()])
    end

    test "nobody in both splits can't be combined" do
      new = override(~D[2026-11-10], ~D[2026-11-12], Suggest.equal([@a]))
      old = override(~D[2026-11-01], ~D[2026-11-30], Suggest.equal([@s]))
      assert {:error, :nobody_in_both} = Bills.plan_combine(new, [old])
    end
  end

  describe "someone's away" do
    test "takes them out of the category's bill split, keeping the others' ratios" do
      template = %{
        category_id: "rent",
        default_split: %{
          "type" => "percentage",
          "entries" => [
            %{"user_id" => "p", "value" => "50"},
            %{"user_id" => "a", "value" => "30"},
            %{"user_id" => "s", "value" => "20"}
          ]
        }
      }

      split = Bills.away_split([template], "rent", ~w(p a s j), @a)
      assert cents(split, 7_000) == %{@p => 5_000, @s => 2_000}
    end

    test "otherwise splits evenly among the other current members" do
      assert Bills.away_split([], "utilities", ~w(p a s), @a) == Suggest.equal([@p, @s])
    end
  end
end
