defmodule Tab.Ledger.FloatTest do
  @moduledoc "Phase 3 test 5: how long money waits, oldest first."
  use ExUnit.Case, async: true

  alias Tab.Ledger.Float

  @p {:user, "p"}
  @s {:user, "s"}

  defp expense(id, date, paid_by, shares) do
    %{
      id: id,
      description: id,
      date: date,
      paid_by: paid_by,
      inserted_at: ~U[2026-10-01 00:00:00Z],
      shares:
        Enum.map(shares, fn {user, cents} ->
          %{user_id: user, counterparty_id: nil, amount_cents: cents}
        end)
    }
  end

  defp payment(date, from, to, cents) do
    %{
      id: "pay-#{date}-#{cents}",
      date: date,
      amount_cents: cents,
      inserted_at: ~U[2026-10-01 00:00:00Z],
      from_user_id: from,
      from_counterparty_id: nil,
      to_user_id: to,
      to_counterparty_id: nil
    }
  end

  defp groceries, do: expense("groceries", ~D[2026-10-01], "p", [{"p", 5_000}, {"s", 5_000}])

  test "a share paid back 9 days later shows 9 days" do
    walk = Float.walk([groceries()], [payment(~D[2026-10-10], "s", "p", 5_000)], ~D[2026-10-30])
    assert walk.shares[{"groceries", @s}] == %{days: 9, open_cents: 0}
    assert walk.by_creditor[@p] == 9
    assert walk.open == %{}
  end

  test "an unpaid share counts up with today" do
    assert Float.walk([groceries()], [], ~D[2026-10-20]).shares[{"groceries", @s}].days == 19
    assert Float.walk([groceries()], [], ~D[2026-10-25]).shares[{"groceries", @s}].days == 24
  end

  test "a partial payment weighs paid and unpaid parts by cents" do
    walk = Float.walk([groceries()], [payment(~D[2026-10-10], "s", "p", 2_000)], ~D[2026-10-20])
    # 20.00 back after 9 days, 30.00 still out after 19: (2000×9 + 3000×19) / 5000 = 15.
    assert walk.shares[{"groceries", @s}] == %{days: 15, open_cents: 3_000}

    assert walk.open[{@s, @p}] == [
             %{
               expense_id: "groceries",
               description: "groceries",
               date: ~D[2026-10-01],
               cents: 3_000
             }
           ]
  end

  test "payments close the oldest shares first" do
    later = expense("power", ~D[2026-10-05], "p", [{"p", 3_000}, {"s", 3_000}])

    walk =
      Float.walk([later, groceries()], [payment(~D[2026-10-10], "s", "p", 6_000)], ~D[2026-10-20])

    assert walk.shares[{"groceries", @s}] == %{days: 9, open_cents: 0}
    # 10.00 back after 5 days, 20.00 out after 15: (1000×5 + 2000×15) / 3000 ≈ 12.
    assert walk.shares[{"power", @s}] == %{days: 12, open_cents: 2_000}
  end

  test "a share owed the other way counts as paid back that day" do
    dinner = expense("dinner", ~D[2026-10-04], "s", [{"p", 2_000}, {"s", 2_000}])
    walk = Float.walk([groceries(), dinner], [], ~D[2026-10-14])

    assert walk.shares[{"dinner", @p}] == %{days: 0, open_cents: 0}
    # 20.00 cancelled after 3 days, 30.00 out after 13: (2000×3 + 3000×13) / 5000 = 9.
    assert walk.shares[{"groceries", @s}] == %{days: 9, open_cents: 3_000}
  end

  test "an overpayment covers the next bill ahead of time" do
    later = expense("later", ~D[2026-10-12], "p", [{"p", 2_000}, {"s", 2_000}])

    walk =
      Float.walk([groceries(), later], [payment(~D[2026-10-10], "s", "p", 7_000)], ~D[2026-10-20])

    assert walk.shares[{"groceries", @s}] == %{days: 9, open_cents: 0}
    assert walk.shares[{"later", @s}] == %{days: 0, open_cents: 0}
    assert walk.open == %{}
  end

  test "an expense with only the payer in it isn't money waiting" do
    solo = expense("solo", ~D[2026-10-01], "p", [{"p", 1_000}])
    assert Float.walk([solo], [], ~D[2026-10-20]).shares == %{}
  end
end
