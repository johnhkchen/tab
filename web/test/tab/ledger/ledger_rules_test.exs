defmodule Tab.Ledger.LedgerRulesTest do
  @moduledoc """
  Phase 1 exit tests 3 to 8 from docs/specification.md: balances against hand
  arithmetic, private expenses, invites, the audit log, payment status, and no
  hard deletes. Raw SQL through `Repo.as_user/2`, like the policy matrix.
  """
  use Tab.DataCase, async: true

  import Tab.LedgerSQL

  defp error_code({:error, %Postgrex.Error{postgres: %{code: code}}}), do: code
  defp error_code(other), do: other

  defp household(n) do
    [admin | rest] = people = Enum.map(1..n, fn _ -> person() end)
    group = create_group!(admin)
    Enum.each(rest, &join!(&1, group, admin))
    {group, people}
  end

  defp confirm!(uid, payment, status \\ "confirmed") do
    run!(uid, "UPDATE payments SET status = $2 WHERE id = $1", [payment, status])
  end

  describe "balances match hand arithmetic" do
    test "Priya's four-person house" do
      {house, [priya, sam, jo, alex]} = household(4)

      expense!(priya, house, 240_000, [
        {priya, 60_000},
        {sam, 60_000},
        {jo, 60_000},
        {alex, 60_000}
      ])

      expense!(sam, house, 12_000, [{priya, 3_000}, {sam, 3_000}, {jo, 3_000}, {alex, 3_000}])
      expense!(jo, house, 8_000, [{jo, 4_000}, {alex, 4_000}])

      expected = [
        {sam, priya, 57_000},
        {jo, priya, 60_000},
        {alex, priya, 60_000},
        {jo, sam, 3_000},
        {alex, sam, 3_000},
        {alex, jo, 4_000}
      ]

      assert balances(jo, house) == Enum.sort(expected)

      # A pending payment changes nothing until the payee confirms it.
      {paid, "pending"} = payment!(alex, house, alex, priya, 30_000)
      assert balances(jo, house) == Enum.sort(expected)

      confirm!(priya, paid)

      after_payment =
        Enum.map(expected, fn
          {^alex, ^priya, _} -> {alex, priya, 30_000}
          row -> row
        end)

      assert balances(jo, house) == Enum.sort(after_payment)
    end

    test "Marcus alone, with counterparties only" do
      marcus = person()
      solo = create_group!(marcus)
      neighbors = counterparty!(marcus, solo, "The Okafors")
      water = category_id(solo, "Utilities")

      expense!(marcus, solo, 9_000, [{marcus, 4_500}, {{:counterparty, neighbors}, 4_500}],
        category_id: water
      )

      assert balances(marcus, solo) == [{{:counterparty, neighbors}, marcus, 4_500}]

      {_, "self_attested"} = payment!(marcus, solo, {:counterparty, neighbors}, marcus, 2_000)
      assert balances(marcus, solo) == [{{:counterparty, neighbors}, marcus, 2_500}]
    end

    test "two partial payments against one balance" do
      {group, [a, b]} = household(2)
      expense!(b, group, 2_000, [{a, 1_000}, {b, 1_000}])

      {first, "pending"} = payment!(a, group, a, b, 300)
      confirm!(b, first)
      # Recorded by the payee, so it's confirmed as it's written.
      {_, "confirmed"} = payment!(b, group, a, b, 200)

      assert balances(a, group) == [{a, b, 500}]
    end

    test "a declined payment doesn't count" do
      {group, [a, b]} = household(2)
      expense!(b, group, 2_000, [{a, 1_000}, {b, 1_000}])

      {p, "pending"} = payment!(a, group, a, b, 1_000)
      confirm!(b, p, "declined")

      assert balances(a, group) == [{a, b, 1_000}]
    end

    test "a soft-deleted expense drops out" do
      {group, [a, b]} = household(2)
      gone = expense!(b, group, 2_000, [{a, 1_000}, {b, 1_000}])
      expense!(a, group, 600, [{a, 300}, {b, 300}])

      assert balances(a, group) == [{a, b, 700}]

      run!(b, "UPDATE expenses SET deleted_at = now() WHERE id = $1", [gone])
      assert balances(a, group) == [{b, a, 300}]
    end

    test "overpaying flips who owes whom" do
      {group, [a, b]} = household(2)
      expense!(b, group, 1_000, [{a, 500}, {b, 500}])
      {_, "confirmed"} = payment!(b, group, a, b, 800)

      assert balances(a, group) == [{b, a, 300}]
    end

    test "category balances net only payments tagged with that category" do
      {group, [a, b]} = household(2)
      rent = category_id(group, "Rent")
      food = category_id(group, "Groceries")

      expense!(b, group, 2_000, [{a, 1_000}, {b, 1_000}], category_id: rent)
      expense!(b, group, 400, [{a, 200}, {b, 200}], category_id: food)
      {_, "confirmed"} = payment!(b, group, a, b, 600, category_id: rent)
      {_, "confirmed"} = payment!(b, group, a, b, 100)

      assert balances(a, group) == [{a, b, 500}]
      assert category_balances(a, group) == Enum.sort([{rent, a, b, 400}, {food, a, b, 200}])
    end
  end

  describe "expense shares" do
    test "must add up to the amount" do
      {group, [a, b]} = household(2)

      assert_raise Postgrex.Error, ~r/add up to 900 cents, not 1000/, fn ->
        expense!(a, group, 1_000, [{a, 450}, {b, 450}])
      end
    end

    test "a private expense has one share, its creator's" do
      {group, [a, b]} = household(2)

      assert_raise Postgrex.Error, ~r/private expense is shared only with its creator/, fn ->
        expense!(a, group, 1_000, [{a, 500}, {b, 500}], visibility: "private")
      end
    end

    test "only people in the group can be in a split" do
      {group, [a, _]} = household(2)
      stranger = person()

      assert_raise Postgrex.Error, ~r/everyone in a split must be in the group/, fn ->
        expense!(a, group, 1_000, [{a, 500}, {stranger, 500}])
      end
    end
  end

  describe "private expenses" do
    setup do
      {group, [admin, owner, other]} = household(3)
      private = expense!(owner, group, 1_500, [{owner, 1_500}], visibility: "private")
      run!(owner, "UPDATE expenses SET description = 'Still mine' WHERE id = $1", [private])
      run!(owner, "UPDATE expenses SET deleted_at = now() WHERE id = $1", [private])
      %{group: group, admin: admin, owner: owner, other: other, private: private}
    end

    test "are invisible to every other member, including the group's creator", ctx do
      for who <- [ctx.admin, ctx.other] do
        assert run!(who, "SELECT 1 FROM expenses WHERE id = $1", [ctx.private]) == []

        assert run!(who, "SELECT 1 FROM expense_shares WHERE expense_id = $1", [ctx.private]) ==
                 []

        assert run!(who, "SELECT 1 FROM audit_log WHERE row_id = $1", [ctx.private]) == []
        assert balances(who, ctx.group) == []
      end
    end

    test "stay visible to their owner, with their history", ctx do
      assert [[_]] = run!(ctx.owner, "SELECT 1 FROM expenses WHERE id = $1", [ctx.private])

      assert run!(
               ctx.owner,
               "SELECT action FROM audit_log WHERE row_id = $1 ORDER BY at, action",
               [
                 ctx.private
               ]
             )
             |> List.flatten()
             |> Enum.sort() == ["insert", "soft_delete", "update"]
    end
  end

  describe "invites" do
    setup do
      admin = person()
      group = create_group!(admin)
      %{admin: admin, group: group, token: invite!(admin, group)}
    end

    defp accept(uid, token), do: run(uid, "SELECT accept_invite($1)", [token])

    defp invalid?({:error, %Postgrex.Error{postgres: %{hint: "invalid_invite"}}}), do: true
    defp invalid?(_), do: false

    test "work once", ctx do
      assert {:ok, _} = accept(person(), ctx.token)
      assert invalid?(accept(person(), ctx.token))
    end

    test "fail after they expire", ctx do
      owner!("UPDATE invites SET expires_at = now() - interval '1 minute' WHERE group_id = $1", [
        ctx.group
      ])

      assert invalid?(accept(person(), ctx.token))
    end

    test "fail once revoked", ctx do
      run!(ctx.admin, "UPDATE invites SET revoked_at = now() WHERE group_id = $1", [ctx.group])
      assert invalid?(accept(person(), ctx.token))
    end

    test "can't be guessed: a wrong token looks exactly like a used one", ctx do
      guess = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      assert invalid?(accept(person(), guess))
      assert invalid?(accept(person(), String.slice(ctx.token, 0..-2//1)))
    end

    test "aren't used up by someone who's already in the group", ctx do
      assert {:error, %{postgres: %{hint: "already_member"}}} = accept(ctx.admin, ctx.token)
      assert {:ok, _} = accept(person(), ctx.token)
    end

    test "can't be pre-used or made to last forever", ctx do
      id = new_id()

      run!(
        ctx.admin,
        """
        INSERT INTO invites (id, group_id, token_hash, used_at, used_by, expires_at)
        VALUES ($1, $2, $3, now(), $4, now() + interval '10 years')
        """,
        [id, ctx.group, {:bytes, :crypto.strong_rand_bytes(32)}, ctx.admin]
      )

      assert owner!(
               "SELECT used_at, used_by, expires_at <= now() + interval '30 days 1 second' FROM invites WHERE id = $1",
               [id]
             ) == [[nil, nil, true]]
    end
  end

  describe "audit" do
    setup do
      {group, [admin, member]} = household(2)
      %{group: group, admin: admin, member: member}
    end

    defp audit_rows(row_id) do
      owner!(
        "SELECT action, actor_id::text FROM audit_log WHERE row_id = $1 ORDER BY at, action",
        [row_id]
      )
    end

    test "every insert, update, and soft delete writes exactly one row with the right actor",
         ctx do
      cp = counterparty!(ctx.member, ctx.group, "Landlord")
      run!(ctx.admin, "UPDATE counterparties SET notes = 'pays late' WHERE id = $1", [cp])
      run!(ctx.member, "UPDATE counterparties SET deleted_at = now() WHERE id = $1", [cp])

      assert Enum.sort(audit_rows(cp)) ==
               Enum.sort([
                 ["insert", ctx.member],
                 ["update", ctx.admin],
                 ["soft_delete", ctx.member]
               ])

      exp = expense!(ctx.member, ctx.group, 1_000, [{ctx.admin, 500}, {ctx.member, 500}])
      assert audit_rows(exp) == [["insert", ctx.member]]

      {pay, "pending"} = payment!(ctx.member, ctx.group, ctx.member, ctx.admin, 500)
      confirm!(ctx.admin, pay)
      assert Enum.sort(audit_rows(pay)) == [["insert", ctx.member], ["update", ctx.admin]]
    end

    test "never stores invite token hashes", ctx do
      assert owner!(
               "SELECT count(*) FROM audit_log WHERE table_name = 'invites' AND after ? 'token_hash'"
             ) ==
               [[0]]

      _ = ctx
    end

    test "can't be changed or deleted by any role the app uses, including the owner", ctx do
      assert error_code(run(ctx.admin, "UPDATE audit_log SET action = 'update'")) ==
               :insufficient_privilege

      for sql <- [
            "UPDATE audit_log SET action = 'update'",
            "DELETE FROM audit_log",
            "TRUNCATE audit_log"
          ] do
        assert_raise Postgrex.Error, ~r/append-only/, fn ->
          Tab.Repo.transaction(fn -> owner!(sql) end)
        end
      end
    end
  end

  describe "payments" do
    test "member to member starts pending, and only the payee can confirm" do
      {group, [a, b, c]} = household(3)
      {p, "pending"} = payment!(a, group, a, b, 1_000, status: "confirmed")

      assert error_code(run(a, "UPDATE payments SET status = 'confirmed' WHERE id = $1", [p])) ==
               :insufficient_privilege

      assert {:ok, %{num_rows: 0}} =
               run(c, "UPDATE payments SET status = 'confirmed' WHERE id = $1", [p])

      confirm!(b, p)
      assert owner!("SELECT status FROM payments WHERE id = $1", [p]) == [["confirmed"]]

      # A decision is final; it can't be flipped back.
      assert error_code(run(b, "UPDATE payments SET status = 'pending' WHERE id = $1", [p])) ==
               :insufficient_privilege
    end

    test "a counterparty payment is self-attested immediately" do
      {group, [a, _b]} = household(2)
      landlord = counterparty!(a, group, "Landlord")
      assert {_, "self_attested"} = payment!(a, group, a, {:counterparty, landlord}, 1_000)
    end

    test "a solo person's payment is self-attested immediately" do
      solo = person()
      group = create_group!(solo)
      utility = counterparty!(solo, group, "Water")
      assert {_, "self_attested"} = payment!(solo, group, {:counterparty, utility}, solo, 1_000)
    end

    test "changing a confirmed payment's amount sends it back to pending" do
      {group, [a, b]} = household(2)
      {p, "pending"} = payment!(a, group, a, b, 1_000)
      confirm!(b, p)
      run!(a, "UPDATE payments SET amount_cents = 2000 WHERE id = $1", [p])

      assert owner!("SELECT status, confirmed_at FROM payments WHERE id = $1", [p]) == [
               ["pending", nil]
             ]
    end

    test "both sides must be in the group" do
      {group, [a, _]} = household(2)
      stranger = person()

      assert_raise Postgrex.Error, ~r/must be members or counterparties/, fn ->
        payment!(a, group, a, stranger, 100)
      end
    end
  end

  describe "leaving a group" do
    defp leave(uid, group, who \\ nil) do
      run(uid, "UPDATE memberships SET left_at = now() WHERE group_id = $1 AND user_id = $2", [
        group,
        who || uid
      ])
    end

    defp unsettled?({:error, %Postgrex.Error{postgres: %{hint: "unsettled"}}}), do: true
    defp unsettled?(_), do: false

    test "takes being even with everyone first" do
      {group, [admin, a, b]} = household(3)
      expense!(b, group, 2_000, [{a, 1_000}, {b, 1_000}])

      assert unsettled?(leave(a, group))
      assert unsettled?(leave(b, group))

      {_, "confirmed"} = payment!(b, group, a, b, 1_000)
      assert {:ok, %{num_rows: 1}} = leave(a, group)
      assert {:ok, %{num_rows: 1}} = leave(b, group)
      assert {:ok, %{num_rows: 1}} = leave(admin, group)
    end

    test "waits for payments you haven't confirmed yet" do
      {group, [_admin, a, b]} = household(3)
      {_, "pending"} = payment!(a, group, a, b, 500)
      assert unsettled?(leave(b, group))
    end

    test "an admin can still remove someone who isn't even, and their debt can still be paid" do
      {group, [admin, a]} = household(2)
      expense!(admin, group, 2_000, [{admin, 1_000}, {a, 1_000}])

      assert {:ok, %{num_rows: 1}} = leave(admin, group, a)
      assert balances(admin, group) == [{a, admin, 1_000}]

      # They can't confirm anything any more, so it counts as soon as it's recorded.
      assert {_, "self_attested"} = payment!(admin, group, a, admin, 400)
      assert {_, "self_attested"} = payment!(admin, group, admin, a, 100)
      assert balances(admin, group) == [{a, admin, 700}]
    end
  end

  describe "editing an expense" do
    test "marks it edited when what was spent or how it's split changes, but not on delete" do
      {group, [a, b]} = household(2)
      e = expense!(a, group, 1_000, [{a, 500}, {b, 500}])

      edited_at = fn ->
        owner!("SELECT edited_at IS NOT NULL FROM expenses WHERE id = $1", [e])
      end

      assert edited_at.() == [[false]]
      run!(a, "UPDATE expenses SET deleted_at = now() WHERE id = $1", [e])
      assert edited_at.() == [[false]]

      run!(a, "UPDATE expenses SET deleted_at = NULL, amount_cents = 1000 WHERE id = $1", [e])
      assert edited_at.() == [[false]]

      run!(a, "UPDATE expenses SET description = 'Dinner, with tip' WHERE id = $1", [e])
      assert edited_at.() == [[true]]
    end

    test "can't be faked as unedited" do
      {group, [a, b]} = household(2)
      e = expense!(a, group, 1_000, [{a, 500}, {b, 500}])
      assert {:error, _} = run(a, "UPDATE expenses SET edited_at = NULL WHERE id = $1", [e])
    end
  end

  describe "an archived group" do
    setup do
      {group, [admin, member]} = household(2)
      e = expense!(member, group, 1_000, [{admin, 500}, {member, 500}])
      run!(admin, "UPDATE groups SET deleted_at = now() WHERE id = $1", [group])
      %{group: group, admin: admin, member: member, expense: e}
    end

    test "is read-only for everyone, admins included", ctx do
      refused = fn result ->
        match?({:error, %{postgres: %{code: :insufficient_privilege}}}, result)
      end

      for who <- [ctx.admin, ctx.member] do
        assert refused.(
                 run(who, "INSERT INTO counterparties (group_id, name) VALUES ($1, 'x')", [
                   ctx.group
                 ])
               )

        assert refused.(
                 run(who, "INSERT INTO categories (group_id, name) VALUES ($1, 'x')", [ctx.group])
               )

        assert refused.(
                 run(
                   who,
                   "INSERT INTO payments (group_id, from_user_id, to_user_id, amount_cents, date, method) VALUES ($1, $2, $3, 1, '2026-10-01', 'cash')",
                   [ctx.group, ctx.member, ctx.admin]
                 )
               )

        assert {:ok, %{num_rows: 0}} =
                 run(who, "UPDATE expenses SET description = 'x' WHERE id = $1", [ctx.expense])

        assert refused.(
                 run(who, "SELECT set_expense_shares($1, $2)", [
                   ctx.expense,
                   shares_json([{ctx.member, 1_000}])
                 ])
               )
      end

      assert refused.(
               run(ctx.admin, "INSERT INTO invites (group_id, token_hash) VALUES ($1, $2)", [
                 ctx.group,
                 {:bytes, :crypto.strong_rand_bytes(32)}
               ])
             )
    end

    test "stays readable, balances included", ctx do
      assert [[_]] = run!(ctx.member, "SELECT 1 FROM groups WHERE id = $1", [ctx.group])
      assert [[_]] = run!(ctx.member, "SELECT 1 FROM expenses WHERE id = $1", [ctx.expense])
      assert balances(ctx.member, ctx.group) == [{ctx.admin, ctx.member, 500}]
    end

    test "comes back when an admin unarchives it", ctx do
      sql = "UPDATE groups SET deleted_at = NULL WHERE id = $1"
      assert {:ok, %{num_rows: 0}} = run(ctx.member, sql, [ctx.group])
      assert {:ok, %{num_rows: 1}} = run(ctx.admin, sql, [ctx.group])
      assert counterparty!(ctx.member, ctx.group, "Landlord")
    end
  end

  describe "the schema itself" do
    test "tab_user lacks DELETE and TRUNCATE on every table and view" do
      rows =
        owner!("""
        SELECT c.relname
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'p')
           AND (has_table_privilege('tab_user', c.oid, 'DELETE')
             OR has_table_privilege('tab_user', c.oid, 'TRUNCATE'))
        """)

      assert rows == []
    end

    test "every table tab_user can touch has RLS on and a policy for each verb" do
      tables =
        owner!("""
        SELECT c.relname, c.relrowsecurity,
               (SELECT array_agg(DISTINCT p.cmd ORDER BY p.cmd) FROM pg_policies p
                 WHERE p.schemaname = 'public' AND p.tablename = c.relname)
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r'
           AND has_any_column_privilege('tab_user', c.oid, 'SELECT, INSERT, UPDATE')
        """)

      assert length(tables) >= 11

      for [table, rls, verbs] <- tables do
        assert rls, "#{table} has RLS off"

        assert verbs == ~w(DELETE INSERT SELECT UPDATE),
               "#{table} has policies for #{inspect(verbs)}"
      end
    end

    test "the app's internal tables are closed to tab_user" do
      for table <- ~w(schema_migrations oban_jobs oban_peers users_tokens) do
        assert owner!(
                 "SELECT has_any_column_privilege('tab_user', $1, 'SELECT, INSERT, UPDATE')",
                 [table]
               ) ==
                 [[false]],
               table
      end
    end
  end
end
