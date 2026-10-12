defmodule Tab.BillsTest do
  @moduledoc """
  Phase 3 through the contexts: recurring bills logged as normal expenses,
  temporary splits saved and combined, statement links made, read, and
  revoked, and float from real rows. The database rules themselves are proven
  in test/tab/ledger/household_db_test.exs.
  """
  use Tab.DataCase, async: true

  import Tab.AccountsFixtures

  alias Tab.{Bills, Groups, Ledger, Statements}
  alias Tab.Bills.Suggest

  setup do
    priya = user_scope_fixture()
    sam = user_scope_fixture()
    {:ok, house} = Groups.create_group(priya, %{name: "Elm Street"})
    {:ok, {token, _}} = Groups.create_invite(priya, house.id)
    {:ok, _} = Groups.accept_invite(sam, token)
    {:ok, cats} = Groups.list_categories(priya, house.id)
    cat = Map.new(cats, &{&1.name, &1.id})
    %{priya: priya, sam: sam, house: house, p: priya.user.id, s: sam.user.id, cat: cat}
  end

  defp log(scope, house, template, amount) do
    pre = Bills.prefill(template, ~D[2026-10-20])
    {from, to} = pre.period || {nil, nil}

    Ledger.create_expense(scope, house.id, %{
      description: pre.description,
      amount_cents: amount,
      date: pre.date,
      category_id: pre.category_id,
      paid_by: pre.paid_by || scope.user.id,
      split: Bills.normal_split(template, []),
      period_start: from,
      period_end: to,
      template_id: template.id
    })
  end

  describe "recurring bills" do
    test "made by hand, logged in one step, and the last amount follows", ctx do
      {:ok, internet} =
        Bills.create_template(ctx.sam, ctx.house.id, %{
          name: "Internet",
          category_id: ctx.cat["Internet"],
          cadence: "monthly",
          stability: "variable",
          default_payer: ctx.p,
          default_split: Suggest.equal([{:user, ctx.p}, {:user, ctx.s}]),
          autopay_day: 31
        })

      assert internet.last_amount_cents == nil

      assert {:ok, first} = log(ctx.sam, ctx.house, internet, 6_000)
      assert first.date == ~D[2026-09-30]
      assert {first.period_start, first.period_end} == {~D[2026-08-30], ~D[2026-09-29]}
      assert first.paid_by == ctx.p
      assert first.template_id == internet.id
      assert Enum.map(first.shares, & &1.amount_cents) == [3_000, 3_000]

      {:ok, internet} = Bills.get_template(ctx.priya, internet.id)
      assert {internet.last_amount_cents, internet.last_logged_on} == {6_000, ~D[2026-09-30]}
      assert Bills.prefill(internet, ~D[2026-10-20]).amount_cents == 6_000

      {:ok, history} = Ledger.history(ctx.priya, ctx.house.id, row_id: first.id)
      assert [%{action: "insert"}] = history
    end

    test "names are unique in a group, and outsiders can't add bills", ctx do
      {:ok, _} =
        Bills.create_template(ctx.priya, ctx.house.id, %{name: "Rent", stability: "fixed"})

      assert {:error, cs} = Bills.create_template(ctx.sam, ctx.house.id, %{name: "rent"})
      assert "is already a bill in this group" in errors_on(cs).name

      assert {:error, _} =
               Bills.create_template(user_scope_fixture(), ctx.house.id, %{name: "Water"})
    end

    test "an unknown split shape is refused before the database sees it", ctx do
      assert {:error, cs} =
               Bills.create_template(ctx.priya, ctx.house.id, %{
                 name: "Rent",
                 default_split: %{"type" => "tiered", "entries" => []}
               })

      assert errors_on(cs).default_split != []
    end
  end

  describe "temporary splits" do
    setup ctx do
      attrs = %{
        category_id: ctx.cat["Utilities"],
        effective_from: ~D[2026-11-01],
        effective_until: ~D[2026-11-30],
        split: Suggest.equal([{:user, ctx.p}]),
        note: "Sam away"
      }

      %{attrs: attrs}
    end

    test "only admins add them", ctx do
      assert {:error, _} = Bills.create_override(ctx.sam, ctx.house.id, ctx.attrs)
      assert {:ok, o} = Bills.create_override(ctx.priya, ctx.house.id, ctx.attrs)
      assert {:ok, [^o]} = Bills.list_overrides(ctx.sam, ctx.house.id)
    end

    test "an overlap is refused; the confirmed plan saves without overlaps", ctx do
      {:ok, old} = Bills.create_override(ctx.priya, ctx.house.id, ctx.attrs)

      new = %{
        ctx.attrs
        | effective_from: ~D[2026-11-20],
          effective_until: ~D[2026-12-10],
          split: Suggest.equal([{:user, ctx.p}, {:user, ctx.s}]),
          note: "Guest"
      }

      assert {:error, :override_overlap} = Bills.create_override(ctx.priya, ctx.house.id, new)

      {:ok, live} = Bills.list_overrides(ctx.priya, ctx.house.id)
      assert [^old] = clashes = Bills.clashes(live, new)
      {:ok, plan} = Bills.plan_combine(new, clashes)
      assert {:ok, 3} = Bills.apply_plan(ctx.priya, ctx.house.id, new, plan)

      {:ok, saved} = Bills.list_overrides(ctx.sam, ctx.house.id)

      assert Enum.map(saved, &{&1.effective_from, &1.effective_until, &1.note}) == [
               {~D[2026-11-01], ~D[2026-11-19], "Sam away"},
               {~D[2026-11-20], ~D[2026-11-30], "Guest and Sam away"},
               {~D[2026-12-01], ~D[2026-12-10], "Guest"}
             ]

      assert hd(saved).id == old.id
    end
  end

  describe "statement links" do
    test "made for one person, read without signing in, then revoked", ctx do
      {:ok, _} =
        Ledger.create_expense(ctx.priya, ctx.house.id, %{
          description: "Electric",
          amount_cents: 9_000,
          date: ~D[2026-10-05],
          paid_by: ctx.p,
          split: Suggest.equal([{:user, ctx.p}, {:user, ctx.s}])
        })

      {:ok, token, link} =
        Statements.create_link(ctx.priya, ctx.house.id, {:user, ctx.s}, ~D[2026-10-17])

      assert {link.period_start, link.period_end} == {~D[2026-10-01], ~D[2026-10-31]}
      assert {:ok, [^link]} = Statements.list_links(ctx.sam, ctx.house.id, {:user, ctx.s})

      assert {:ok, %{"expenses" => [%{"description" => "Electric", "share_cents" => 4_500}]}} =
               Statements.read(token)

      assert {:ok, :done} = Statements.revoke_link(ctx.sam, link.id)
      assert {:error, :invalid_statement} = Statements.read(token)
      assert {:error, :invalid_statement} = Statements.read("nope")
      assert {:ok, []} = Statements.list_links(ctx.sam, ctx.house.id, {:user, ctx.s})
    end
  end

  test "float from real rows: confirmed payments count, pending ones don't", ctx do
    {:ok, e} =
      Ledger.create_expense(ctx.priya, ctx.house.id, %{
        description: "Groceries",
        amount_cents: 10_000,
        date: ~D[2026-10-01],
        paid_by: ctx.p,
        split: Suggest.equal([{:user, ctx.p}, {:user, ctx.s}])
      })

    {:ok, pay} =
      Ledger.record_payment(ctx.sam, ctx.house.id, %{
        from_user_id: ctx.s,
        to_user_id: ctx.p,
        amount_cents: 5_000,
        date: ~D[2026-10-10],
        method: "venmo"
      })

    {:ok, walk} = Ledger.float(ctx.sam, ctx.house.id, ~D[2026-10-21])
    assert walk.shares[{e.id, {:user, ctx.s}}] == %{days: 20, open_cents: 5_000}

    {:ok, _} = Ledger.confirm_payment(ctx.priya, pay.id)
    {:ok, walk} = Ledger.float(ctx.sam, ctx.house.id, ~D[2026-10-21])
    assert walk.shares[{e.id, {:user, ctx.s}}] == %{days: 9, open_cents: 0}
    assert walk.by_creditor[{:user, ctx.p}] == 9
  end
end
