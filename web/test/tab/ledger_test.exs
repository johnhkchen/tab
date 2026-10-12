defmodule Tab.LedgerTest do
  @moduledoc """
  The contexts end to end. The database rules themselves are proven in
  test/tab/ledger/; these check that `Tab.Groups` and `Tab.Ledger` use them
  and hand back plain results.
  """
  use Tab.DataCase, async: true

  import Tab.AccountsFixtures

  alias Tab.{Groups, Ledger}

  setup do
    priya = user_scope_fixture()
    sam = user_scope_fixture()
    {:ok, house} = Groups.create_group(priya, %{name: "  Elm Street  "})
    {:ok, {token, _}} = Groups.create_invite(priya, house.id)
    {:ok, _} = Groups.accept_invite(sam, token)
    %{priya: priya, sam: sam, house: house, p: priya.user.id, s: sam.user.id}
  end

  defp equal(ids), do: %{"type" => "equal", "entries" => Enum.map(ids, &%{"user_id" => &1})}

  describe "groups" do
    test "the creator is admin, the invitee is a member, and both see the group", ctx do
      assert ctx.house.name == "Elm Street"
      assert ctx.house.created_by == ctx.p

      {:ok, members} = Groups.list_members(ctx.sam, ctx.house.id)
      assert Enum.map(members, &{&1.user_id, &1.role}) == [{ctx.p, "admin"}, {ctx.s, "member"}]
      assert Enum.all?(members, &is_binary(&1.profile.display_name))

      assert {:ok, [%{id: id}]} = Groups.list_groups(ctx.sam)
      assert id == ctx.house.id
    end

    test "invites are single-use and only admins make them", ctx do
      {:ok, {token, _}} = Groups.create_invite(ctx.priya, ctx.house.id)
      assert {:ok, _} = Groups.accept_invite(user_scope_fixture(), token)
      assert {:error, :invalid_invite} = Groups.accept_invite(user_scope_fixture(), token)
      {:ok, {another, _}} = Groups.create_invite(ctx.priya, ctx.house.id)
      assert {:error, :already_member} = Groups.accept_invite(ctx.sam, another)
      assert {:error, :forbidden} = Groups.create_invite(ctx.sam, ctx.house.id)
    end

    test "outsiders get nothing", ctx do
      stranger = user_scope_fixture()
      assert {:error, :not_found} = Groups.get_group(stranger, ctx.house.id)
      assert {:ok, []} = Groups.list_members(stranger, ctx.house.id)
      assert {:error, :not_found} = Groups.rename_group(stranger, ctx.house.id, "Mine")
    end

    test "you can't leave owing money; an admin can still remove you", ctx do
      {:ok, _} =
        Ledger.create_expense(ctx.priya, ctx.house.id, %{
          description: "Rent",
          amount_cents: 2_000,
          date: ~D[2026-10-01],
          paid_by: ctx.p,
          split: equal([ctx.p, ctx.s])
        })

      assert {:error, :unsettled} = Groups.leave_group(ctx.sam, ctx.house.id)
      assert {:error, :not_found} = Groups.remove_member(ctx.sam, ctx.house.id, ctx.p)
      assert {:ok, :done} = Groups.remove_member(ctx.priya, ctx.house.id, ctx.s)
      assert {:ok, [%{amount_cents: 1_000}]} = Ledger.balances(ctx.priya, ctx.house.id)
    end

    test "an archived group is read-only until an admin unarchives it", ctx do
      assert {:ok, :done} = Groups.archive_group(ctx.priya, ctx.house.id)

      assert {:error, :forbidden} =
               Groups.create_counterparty(ctx.sam, ctx.house.id, %{name: "Landlord"})

      assert {:ok, [_]} = Groups.list_groups(ctx.sam)
      assert {:ok, :done} = Groups.unarchive_group(ctx.priya, ctx.house.id)
      assert {:ok, _} = Groups.create_counterparty(ctx.sam, ctx.house.id, %{name: "Landlord"})
    end

    test "only admins rename; a member can leave", ctx do
      assert {:error, %Ecto.Changeset{}} = Groups.rename_group(ctx.sam, ctx.house.id, "Ours")
      assert {:ok, %{name: "Ours"}} = Groups.rename_group(ctx.priya, ctx.house.id, "Ours")
      assert {:ok, :done} = Groups.leave_group(ctx.sam, ctx.house.id)
      assert {:ok, []} = Groups.list_groups(ctx.sam)
    end

    test "starter categories, and counterparties", ctx do
      {:ok, categories} = Groups.list_categories(ctx.sam, ctx.house.id)
      assert "Rent" in Enum.map(categories, & &1.name)
      assert {:error, %Ecto.Changeset{}} = Groups.create_category(ctx.sam, ctx.house.id, "rent")

      {:ok, landlord} = Groups.create_counterparty(ctx.sam, ctx.house.id, %{name: "Landlord"})
      assert {:ok, [%{name: "Landlord"}]} = Groups.list_counterparties(ctx.priya, ctx.house.id)
      assert {:ok, :done} = Groups.archive_counterparty(ctx.priya, landlord.id)
      assert {:ok, []} = Groups.list_counterparties(ctx.priya, ctx.house.id)
    end
  end

  describe "expenses" do
    test "are split, stored with their shares, and show in balances", ctx do
      {:ok, expense} =
        Ledger.create_expense(ctx.priya, ctx.house.id, %{
          description: "Internet",
          amount_cents: 10_001,
          date: ~D[2026-10-01],
          paid_by: ctx.p,
          split: equal([ctx.p, ctx.s])
        })

      assert expense.created_by == ctx.p
      assert Enum.map(expense.shares, & &1.amount_cents) |> Enum.sort() == [5_000, 5_001]

      assert {:ok, [%{debtor: {:user, debtor}, creditor: {:user, creditor}, amount_cents: 5_000}]} =
               Ledger.balances(ctx.sam, ctx.house.id)

      assert {debtor, creditor} == {ctx.s, ctx.p}
    end

    test "a bad split comes back as a changeset error, with nothing saved", ctx do
      split = %{"type" => "exact", "entries" => [%{"user_id" => ctx.p, "value" => 100}]}

      assert {:error, changeset} =
               Ledger.create_expense(ctx.priya, ctx.house.id, %{
                 description: "Oops",
                 amount_cents: 500,
                 date: ~D[2026-10-01],
                 paid_by: ctx.p,
                 split: split
               })

      assert %{split: ["exact amounts add up to 100 cents, not 500"]} = errors_on(changeset)
      assert {:ok, []} = Ledger.list_expenses(ctx.priya, ctx.house.id)
    end

    test "editing re-splits; another member can't edit; deleting drops it from balances", ctx do
      {:ok, e} =
        Ledger.create_expense(ctx.priya, ctx.house.id, %{
          description: "Rent",
          amount_cents: 2_000,
          date: ~D[2026-10-01],
          paid_by: ctx.p,
          split: equal([ctx.p, ctx.s])
        })

      assert {:error, %Ecto.Changeset{}} =
               Ledger.update_expense(ctx.sam, e.id, %{amount_cents: 1})

      assert e.edited_at == nil
      {:ok, e} = Ledger.update_expense(ctx.priya, e.id, %{amount_cents: 3_000})
      assert Enum.map(e.shares, & &1.amount_cents) == [1_500, 1_500]
      assert %DateTime{} = e.edited_at

      assert {:ok, :done} = Ledger.delete_expense(ctx.priya, e.id)
      assert {:ok, []} = Ledger.balances(ctx.sam, ctx.house.id)
    end

    test "someone outside the group can't be in a split", ctx do
      stranger = user_fixture()

      assert {:error, {:invalid, "everyone in a split must be in the group"}} =
               Ledger.create_expense(ctx.priya, ctx.house.id, %{
                 description: "Pizza",
                 amount_cents: 2_000,
                 date: ~D[2026-10-01],
                 paid_by: ctx.p,
                 split: equal([ctx.p, stranger.id])
               })
    end
  end

  describe "payments and settling up" do
    setup ctx do
      {:ok, _} =
        Ledger.create_expense(ctx.priya, ctx.house.id, %{
          description: "Groceries",
          amount_cents: 4_000,
          date: ~D[2026-10-01],
          paid_by: ctx.p,
          split: equal([ctx.p, ctx.s])
        })

      :ok
    end

    defp pay(scope, ctx, amount) do
      Ledger.record_payment(scope, ctx.house.id, %{
        from_user_id: ctx.s,
        to_user_id: ctx.p,
        amount_cents: amount,
        date: ~D[2026-10-02],
        method: "venmo"
      })
    end

    test "a pending payment counts only once the payee confirms", ctx do
      {:ok, payment} = pay(ctx.sam, ctx, 500)
      assert payment.status == "pending"
      assert {:error, :forbidden} = Ledger.confirm_payment(ctx.sam, payment.id)

      assert {:ok, %{status: "confirmed", confirmed_by: by}} =
               Ledger.confirm_payment(ctx.priya, payment.id)

      assert by == ctx.p
      assert {:ok, [%{amount_cents: 1_500}]} = Ledger.balances(ctx.priya, ctx.house.id)
    end

    test "settle-up suggests the payment that zeroes the group", ctx do
      {:ok, [suggestion]} = Ledger.settle_up(ctx.sam, ctx.house.id)
      assert suggestion == %{from: {:user, ctx.s}, to: {:user, ctx.p}, amount_cents: 2_000}

      {:ok, _} = pay(ctx.priya, ctx, 2_000)
      assert {:ok, []} = Ledger.settle_up(ctx.sam, ctx.house.id)
    end
  end

  test "settle/1 needs at most one fewer payment than people with a balance" do
    [a, b, c, d] = Enum.map(1..4, &{:user, "#{&1}"})

    balances = [
      %{debtor: a, creditor: b, amount_cents: 1_000},
      %{debtor: b, creditor: c, amount_cents: 1_000},
      %{debtor: d, creditor: c, amount_cents: 500},
      %{debtor: a, creditor: d, amount_cents: 200}
    ]

    payments = Ledger.settle(balances)
    assert length(payments) <= 3

    net = fn party ->
      Enum.sum(for(%{to: ^party, amount_cents: n} <- payments, do: n)) -
        Enum.sum(for(%{from: ^party, amount_cents: n} <- payments, do: n))
    end

    # a owes 1200, c is owed 1500, d owes 300, b is even.
    assert {net.(a), net.(b), net.(c), net.(d)} == {-1_200, 0, 1_500, -300}
  end
end
