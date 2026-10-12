defmodule Tab.Ledger.PolicyMatrixTest do
  @moduledoc """
  The policy matrix from docs/specification.md ("Row-level security, table by
  table"): every table, every verb, run as an admin, a member, another member,
  the private-expense owner, and an outsider, in raw SQL through
  `Repo.as_user/2`. Nothing here goes through the contexts.

  The world:

    * `admin` made the group, so they're its admin.
    * `member` joined by invite. They own the private expense.
    * `other` joined by invite.
    * `outsider` is signed in but not in the group (they have a group of their own).
  """
  use Tab.DataCase, async: true

  import Tab.LedgerSQL

  setup do
    admin = person()
    member = person()
    other = person()
    outsider = person()

    group = create_group!(admin, "Priya's house")
    join!(member, group, admin)
    join!(other, group, admin)
    _elsewhere = create_group!(outsider, "Somewhere else")

    landlord = counterparty!(member, group, "Landlord")
    rent = category_id(group, "Rent")

    shared =
      expense!(member, group, 9_000, [{admin, 3_000}, {member, 3_000}, {other, 3_000}],
        category_id: rent
      )

    private = expense!(member, group, 1_200, [{member, 1_200}], visibility: "private")
    {payment, "pending"} = payment!(member, group, member, admin, 1_000)
    token = invite!(admin, group)
    [[invite]] = owner!("SELECT id FROM invites WHERE group_id = $1 LIMIT 1", [group])

    %{
      admin: admin,
      member: member,
      other: other,
      outsider: outsider,
      group: group,
      landlord: landlord,
      rent: rent,
      shared: shared,
      private: private,
      payment: payment,
      token: token,
      invite: invite
    }
  end

  defp refused?({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}), do: true
  defp refused?(_), do: false

  defp rows({:ok, %{num_rows: n}}), do: n

  defp count(uid, sql, params) do
    [[n]] = run!(uid, "SELECT count(*) FROM (#{sql}) t", params)
    n
  end

  @tables ~w(users users_tokens profiles groups memberships invites counterparties categories
             expenses expense_shares payments audit_log)

  test "nobody can delete from any table, not even their own rows", ctx do
    for table <- @tables, who <- [:admin, :member, :other, :outsider] do
      assert refused?(run(ctx[who], "DELETE FROM #{table}")),
             "#{who} could DELETE FROM #{table}"
    end
  end

  describe "users" do
    test "each person sees only their own row", ctx do
      for who <- [:admin, :member, :outsider] do
        assert run!(ctx[who], "SELECT id::text FROM users") == [[ctx[who]]]
      end
    end

    test "nobody inserts or updates users directly", ctx do
      assert refused?(run(ctx.member, "INSERT INTO users (email) VALUES ('x@example.com')"))
      assert refused?(run(ctx.member, "UPDATE users SET email = 'x@example.com'"))
    end

    test "sign-in tokens are invisible", ctx do
      assert refused?(run(ctx.member, "SELECT * FROM users_tokens"))
    end
  end

  describe "profiles" do
    test "visible to yourself and to people you share a group with", ctx do
      ids = fn who -> run!(ctx[who], "SELECT user_id::text FROM profiles") |> List.flatten() end

      assert Enum.sort(ids.(:member)) == Enum.sort([ctx.admin, ctx.member, ctx.other])
      assert ids.(:outsider) == [ctx.outsider]
    end

    test "only your own can be changed; nobody inserts", ctx do
      assert rows(
               run(ctx.member, "UPDATE profiles SET display_name = 'M' WHERE user_id = $1", [
                 ctx.member
               ])
             ) == 1

      assert rows(
               run(ctx.member, "UPDATE profiles SET display_name = 'X' WHERE user_id = $1", [
                 ctx.admin
               ])
             ) == 0

      assert refused?(
               run(ctx.member, "INSERT INTO profiles (user_id, display_name) VALUES ($1, 'x')", [
                 ctx.outsider
               ])
             )
    end

    test "payment methods must be known kinds with a handle", ctx do
      ok = [%{"kind" => "venmo", "handle" => "@m"}]
      bad = [%{"kind" => "bitcoin", "handle" => "x"}]
      sql = "UPDATE profiles SET payment_methods = $2::jsonb WHERE user_id = $1"

      assert rows(run(ctx.member, sql, [ctx.member, ok])) == 1

      assert {:error, %{postgres: %{code: :check_violation}}} =
               run(ctx.member, sql, [ctx.member, bad])
    end
  end

  describe "groups" do
    test "members see the group; outsiders don't", ctx do
      for who <- [:admin, :member, :other] do
        assert count(ctx[who], "SELECT 1 FROM groups WHERE id = $1", [ctx.group]) == 1
      end

      assert count(ctx.outsider, "SELECT 1 FROM groups WHERE id = $1", [ctx.group]) == 0
    end

    test "anyone signed in can make one, as themselves, and becomes its admin", ctx do
      id = new_id()

      run!(ctx.outsider, "INSERT INTO groups (id, name, created_by) VALUES ($1, 'Mine', $2)", [
        id,
        ctx.admin
      ])

      assert owner!("SELECT created_by::text FROM groups WHERE id = $1", [id]) == [[ctx.outsider]]

      assert owner!("SELECT user_id::text, role FROM memberships WHERE group_id = $1", [id]) ==
               [[ctx.outsider, "admin"]]

      assert count(ctx.outsider, "SELECT 1 FROM categories WHERE group_id = $1", [id]) == 7
    end

    test "nobody signed out can make one" do
      # as_user always sets a person, so this checks the policy's NULL guard as tab_user.
      {:error, result} =
        Tab.Repo.transaction(fn ->
          Tab.Repo.query!("SET LOCAL ROLE tab_user")

          Tab.Repo.query(
            "INSERT INTO groups (id, name, created_by) VALUES (gen_random_uuid(), 'x', gen_random_uuid())"
          )
          |> Tab.Repo.rollback()
        end)

      assert refused?(result)
    end

    test "only admins rename or archive", ctx do
      sql = "UPDATE groups SET name = 'Renamed' WHERE id = $1"
      assert rows(run(ctx.member, sql, [ctx.group])) == 0
      assert rows(run(ctx.outsider, sql, [ctx.group])) == 0
      assert rows(run(ctx.admin, sql, [ctx.group])) == 1

      assert refused?(
               run(ctx.admin, "UPDATE groups SET created_by = $2 WHERE id = $1", [
                 ctx.group,
                 ctx.member
               ])
             )
    end
  end

  describe "memberships" do
    test "members see the group's memberships; outsiders don't", ctx do
      assert count(ctx.member, "SELECT 1 FROM memberships WHERE group_id = $1", [ctx.group]) == 3

      assert count(ctx.outsider, "SELECT 1 FROM memberships WHERE group_id = $1", [ctx.group]) ==
               0
    end

    test "nobody inserts memberships directly", ctx do
      for who <- [:admin, :outsider] do
        assert refused?(
                 run(ctx[who], "INSERT INTO memberships (group_id, user_id) VALUES ($1, $2)", [
                   ctx.group,
                   ctx.outsider
                 ])
               )
      end
    end

    test "admins change roles; members can't", ctx do
      sql = "UPDATE memberships SET role = 'admin' WHERE group_id = $1 AND user_id = $2"
      assert rows(run(ctx.member, sql, [ctx.group, ctx.other])) == 0
      assert refused?(run(ctx.member, sql, [ctx.group, ctx.member]))
      assert rows(run(ctx.admin, sql, [ctx.group, ctx.other])) == 1
    end

    test "a member can leave, and then sees nothing of the group but their own row", ctx do
      sql = "UPDATE memberships SET left_at = now() WHERE group_id = $1 AND user_id = $2"
      assert rows(run(ctx.member, sql, [ctx.group, ctx.member])) == 1

      assert count(ctx.member, "SELECT 1 FROM groups WHERE id = $1", [ctx.group]) == 0
      assert count(ctx.member, "SELECT 1 FROM memberships WHERE group_id = $1", [ctx.group]) == 1
      assert count(ctx.member, "SELECT 1 FROM expenses WHERE id = $1", [ctx.shared]) == 0

      # ...and can't rejoin by clearing left_at.
      assert rows(
               run(ctx.member, "UPDATE memberships SET left_at = NULL WHERE user_id = $1", [
                 ctx.member
               ])
             ) == 0
    end
  end

  describe "invites" do
    test "only admins see them", ctx do
      assert count(ctx.admin, "SELECT 1 FROM invites", []) >= 1
      assert count(ctx.member, "SELECT 1 FROM invites", []) == 0
      assert count(ctx.outsider, "SELECT 1 FROM invites", []) == 0
    end

    test "only admins make them", ctx do
      sql = "INSERT INTO invites (group_id, token_hash) VALUES ($1, $2)"
      hash = {:bytes, :crypto.strong_rand_bytes(32)}
      assert refused?(run(ctx.member, sql, [ctx.group, hash]))
      assert refused?(run(ctx.outsider, sql, [ctx.group, hash]))
    end

    test "only admins revoke them, and only revoke", ctx do
      sql = "UPDATE invites SET revoked_at = now() WHERE id = $1"
      assert rows(run(ctx.member, sql, [ctx.invite])) == 0
      assert rows(run(ctx.admin, sql, [ctx.invite])) == 1

      assert refused?(
               run(ctx.admin, "UPDATE invites SET used_at = now() WHERE id = $1", [ctx.invite])
             )

      assert refused?(
               run(ctx.admin, "UPDATE invites SET revoked_at = NULL WHERE id = $1", [ctx.invite])
             )
    end
  end

  for {table, insert} <- [
        counterparties: "INSERT INTO counterparties (group_id, name) VALUES ($1, 'Neighbors')",
        categories: "INSERT INTO categories (group_id, name) VALUES ($1, 'Pets')"
      ] do
    describe "#{table}" do
      test "members see, add, and change them; outsiders can't", ctx do
        table = unquote(table)

        assert count(ctx.other, "SELECT 1 FROM #{table} WHERE group_id = $1", [ctx.group]) > 0
        assert count(ctx.outsider, "SELECT 1 FROM #{table} WHERE group_id = $1", [ctx.group]) == 0

        assert rows(run(ctx.other, unquote(insert), [ctx.group])) == 1
        assert refused?(run(ctx.outsider, unquote(insert), [ctx.group]))

        update = "UPDATE #{table} SET name = name || '!' WHERE group_id = $1"
        assert rows(run(ctx.outsider, update, [ctx.group])) == 0
        assert rows(run(ctx.other, update, [ctx.group])) > 0
      end
    end
  end

  describe "expenses" do
    test "shared ones are visible to members only", ctx do
      for who <- [:admin, :member, :other] do
        assert count(ctx[who], "SELECT 1 FROM expenses WHERE id = $1", [ctx.shared]) == 1
      end

      assert count(ctx.outsider, "SELECT 1 FROM expenses WHERE id = $1", [ctx.shared]) == 0
    end

    test "private ones are visible to their creator only, not even the group's admin", ctx do
      assert count(ctx.member, "SELECT 1 FROM expenses WHERE id = $1", [ctx.private]) == 1

      for who <- [:admin, :other, :outsider] do
        assert count(ctx[who], "SELECT 1 FROM expenses WHERE id = $1", [ctx.private]) == 0
      end
    end

    @insert """
    INSERT INTO expenses (id, group_id, description, amount_cents, date, paid_by, visibility, split, created_by)
    VALUES (gen_random_uuid(), $1, 'Groceries', 500, '2026-10-02', $2, $3, '{"type":"equal"}', $4)
    """

    test "members add them as themselves; the creator is never taken from the client", ctx do
      assert rows(run(ctx.other, @insert, [ctx.group, ctx.admin, "shared", ctx.admin])) == 1

      assert owner!("SELECT created_by::text FROM expenses WHERE description = 'Groceries'") ==
               [[ctx.other]]
    end

    test "a private expense must be paid by its creator", ctx do
      assert refused?(run(ctx.other, @insert, [ctx.group, ctx.admin, "private", ctx.other]))
      assert rows(run(ctx.other, @insert, [ctx.group, ctx.other, "private", ctx.other])) == 1
    end

    test "outsiders can't add them, and the payer must be a member", ctx do
      assert refused?(run(ctx.outsider, @insert, [ctx.group, ctx.admin, "shared", ctx.outsider]))

      assert {:error, %{postgres: %{code: :check_violation}}} =
               run(ctx.member, @insert, [ctx.group, ctx.outsider, "shared", ctx.member])
    end

    test "the creator or an admin edits a shared one; other members and outsiders can't", ctx do
      sql = "UPDATE expenses SET description = 'Edited' WHERE id = $1"
      assert rows(run(ctx.other, sql, [ctx.shared])) == 0
      assert rows(run(ctx.outsider, sql, [ctx.shared])) == 0
      assert rows(run(ctx.member, sql, [ctx.shared])) == 1
      assert rows(run(ctx.admin, sql, [ctx.shared])) == 1
    end

    test "only the creator edits a private one", ctx do
      sql = "UPDATE expenses SET description = 'Edited' WHERE id = $1"
      assert rows(run(ctx.admin, sql, [ctx.private])) == 0
      assert rows(run(ctx.member, sql, [ctx.private])) == 1
    end

    test "nobody moves an expense to another group or changes its creator", ctx do
      assert refused?(
               run(ctx.member, "UPDATE expenses SET created_by = $2 WHERE id = $1", [
                 ctx.shared,
                 ctx.admin
               ])
             )

      assert refused?(
               run(ctx.member, "UPDATE expenses SET group_id = $2 WHERE id = $1", [
                 ctx.shared,
                 new_id()
               ])
             )
    end
  end

  describe "expense_shares" do
    test "follow their expense", ctx do
      for who <- [:admin, :member, :other] do
        assert count(ctx[who], "SELECT 1 FROM expense_shares WHERE expense_id = $1", [ctx.shared]) ==
                 3
      end

      assert count(ctx.outsider, "SELECT 1 FROM expense_shares WHERE expense_id = $1", [
               ctx.shared
             ]) == 0

      assert count(ctx.member, "SELECT 1 FROM expense_shares WHERE expense_id = $1", [ctx.private]) ==
               1

      assert count(ctx.admin, "SELECT 1 FROM expense_shares WHERE expense_id = $1", [ctx.private]) ==
               0
    end

    test "nobody writes them directly", ctx do
      assert refused?(
               run(
                 ctx.member,
                 "INSERT INTO expense_shares (expense_id, group_id, user_id, amount_cents) VALUES ($1, $2, $3, 1)",
                 [
                   ctx.shared,
                   ctx.group,
                   ctx.member
                 ]
               )
             )

      assert refused?(run(ctx.member, "UPDATE expense_shares SET amount_cents = 0"))
    end

    test "only someone who may edit the expense can re-split it", ctx do
      shares = shares_json([{ctx.admin, 4_500}, {ctx.member, 4_500}])
      sql = "SELECT set_expense_shares($1, $2)"

      assert refused?(run(ctx.other, sql, [ctx.shared, shares]))
      assert refused?(run(ctx.outsider, sql, [ctx.shared, shares]))
      assert {:ok, _} = run(ctx.admin, sql, [ctx.shared, shares])
      assert refused?(run(ctx.admin, sql, [ctx.private, shares_json([{ctx.member, 1_200}])]))
    end
  end

  describe "payments" do
    test "members see them; outsiders don't", ctx do
      assert count(ctx.other, "SELECT 1 FROM payments WHERE id = $1", [ctx.payment]) == 1
      assert count(ctx.outsider, "SELECT 1 FROM payments WHERE id = $1", [ctx.payment]) == 0
    end

    test "members record them as themselves; outsiders can't", ctx do
      sql = """
      INSERT INTO payments (group_id, from_user_id, to_user_id, amount_cents, date, method, recorded_by)
      VALUES ($1, $2, $3, 100, '2026-10-03', 'cash', $4)
      """

      assert rows(run(ctx.other, sql, [ctx.group, ctx.other, ctx.admin, ctx.admin])) == 1

      assert owner!("SELECT recorded_by::text FROM payments WHERE amount_cents = 100") ==
               [[ctx.other]]

      assert refused?(run(ctx.outsider, sql, [ctx.group, ctx.admin, ctx.member, ctx.outsider]))
    end

    test "only the payee confirms; the payer and bystanders can't", ctx do
      sql = "UPDATE payments SET status = 'confirmed' WHERE id = $1"
      assert refused?(run(ctx.member, sql, [ctx.payment]))
      assert rows(run(ctx.other, sql, [ctx.payment])) == 0
      assert rows(run(ctx.outsider, sql, [ctx.payment])) == 0
      assert rows(run(ctx.admin, sql, [ctx.payment])) == 1

      assert owner!("SELECT status, confirmed_by::text FROM payments WHERE id = $1", [ctx.payment]) ==
               [["confirmed", ctx.admin]]
    end

    test "only the recorder edits details", ctx do
      sql = "UPDATE payments SET reference = 'rent' WHERE id = $1"
      assert refused?(run(ctx.admin, sql, [ctx.payment]))
      assert rows(run(ctx.other, sql, [ctx.payment])) == 0
      assert rows(run(ctx.member, sql, [ctx.payment])) == 1
    end
  end

  describe "audit_log" do
    test "members read their group's history; outsiders don't", ctx do
      assert count(ctx.other, "SELECT 1 FROM audit_log WHERE group_id = $1", [ctx.group]) > 0
      assert count(ctx.outsider, "SELECT 1 FROM audit_log WHERE group_id = $1", [ctx.group]) == 0
    end

    test "nobody writes it directly", ctx do
      assert refused?(
               run(
                 ctx.admin,
                 "INSERT INTO audit_log (group_id, table_name, row_id, action) VALUES ($1, 'x', $1, 'insert')",
                 [
                   ctx.group
                 ]
               )
             )

      assert refused?(run(ctx.admin, "UPDATE audit_log SET action = 'update'"))
    end
  end

  describe "balances" do
    test "outsiders see none of the group's", ctx do
      assert balances(ctx.outsider, ctx.group) == []
      assert balances(ctx.admin, ctx.group) != []
    end
  end
end
