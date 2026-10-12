defmodule Tab.Ledger.HouseholdDbTest do
  @moduledoc """
  Phase 3 tests 1 and 2, and the database halves of 3 and 4: the policy matrix
  for `recurring_templates`, `split_overrides`, and `statement_links`; statement
  links read straight from the database as nobody; template `last_*` kept by a
  trigger; and overlapping temporary splits refused. Raw SQL through
  `Repo.as_user/2`, never the contexts.
  """
  use Tab.DataCase, async: true

  import Tab.LedgerSQL

  alias Tab.Repo

  setup do
    admin = person()
    member = person()
    outsider = person()
    group = create_group!(admin, "Elm Street")
    join!(member, group, admin)
    _elsewhere = create_group!(outsider, "Somewhere else")
    utilities = category_id(group, "Utilities")
    rent = category_id(group, "Rent")

    %{
      admin: admin,
      member: member,
      outsider: outsider,
      group: group,
      utilities: utilities,
      rent: rent
    }
  end

  defp refused?({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}), do: true
  defp refused?(_), do: false

  defp rows({:ok, %{num_rows: n}}), do: n

  defp template!(uid, group, attrs \\ %{}) do
    id = new_id()

    run!(
      uid,
      """
      INSERT INTO recurring_templates (id, group_id, name, cadence, stability, default_split,
                                       last_amount_cents)
      VALUES ($1, $2, $3, 'monthly', $4, $5, $6)
      """,
      [
        id,
        group,
        Map.get(attrs, :name, "Internet"),
        Map.get(attrs, :stability, "variable"),
        Map.get(attrs, :split),
        Map.get(attrs, :last, 99_999)
      ]
    )

    id
  end

  defp override!(uid, group, from, until, opts \\ []) do
    id = new_id()

    run(
      uid,
      """
      INSERT INTO split_overrides (id, group_id, category_id, effective_from, effective_until, split)
      VALUES ($1, $2, $3, $4, $5, $6)
      """,
      [
        id,
        group,
        Keyword.get(opts, :category_id),
        from,
        until,
        Keyword.get(opts, :split, %{"type" => "equal", "entries" => [%{"user_id" => uid}]})
      ]
    )
    |> case do
      {:ok, _} -> {:ok, id}
      error -> error
    end
  end

  defp link!(uid, group, party, opts \\ []) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {user, cp} =
      if match?({:counterparty, _}, party), do: {nil, elem(party, 1)}, else: {party, nil}

    run!(
      uid,
      """
      INSERT INTO statement_links (id, group_id, token_hash, user_id, counterparty_id,
                                   period_start, period_end, expires_at, revoked_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """,
      [
        new_id(),
        group,
        {:bytes, :crypto.hash(:sha256, token)},
        user,
        cp,
        Keyword.get(opts, :from, ~D[2026-10-01]),
        Keyword.get(opts, :to, ~D[2026-10-31]),
        Keyword.get(opts, :expires_at, ~N[2099-01-01 00:00:00]),
        Keyword.get(opts, :revoked_at)
      ]
    )

    token
  end

  defp statement(token) do
    Repo.as_nobody(fn ->
      case Repo.query("SELECT read_statement($1)", [token]) do
        {:ok, %{rows: [[s]]}} -> s
        {:error, e} -> Repo.rollback(e)
      end
    end)
  end

  describe "recurring_templates" do
    test "members read, add, and change; outsiders can't see or touch them", ctx do
      t = template!(ctx.member, ctx.group)

      assert count_rows(ctx.admin, "recurring_templates", t) == 1
      assert count_rows(ctx.outsider, "recurring_templates", t) == 0

      assert rows(
               run(ctx.admin, "UPDATE recurring_templates SET name = 'Fiber' WHERE id = $1", [t])
             ) ==
               1

      assert rows(
               run(ctx.outsider, "UPDATE recurring_templates SET name = 'x' WHERE id = $1", [t])
             ) ==
               0

      assert {:error, %Postgrex.Error{}} =
               run(
                 ctx.outsider,
                 "INSERT INTO recurring_templates (id, group_id, name) VALUES ($1, $2, 'x')",
                 [new_id(), ctx.group]
               )
    end

    test "people can't set the last amount; it follows the newest live expense", ctx do
      t = template!(ctx.member, ctx.group, %{last: 12_345})
      assert [[nil, nil]] = last_logged(t)

      assert refused?(
               run(
                 ctx.member,
                 "UPDATE recurring_templates SET last_amount_cents = 1 WHERE id = $1",
                 [t]
               )
             )

      e1 = expense!(ctx.member, ctx.group, 6_000, [{ctx.member, 6_000}], date: ~D[2026-09-03])
      e2 = expense!(ctx.member, ctx.group, 6_500, [{ctx.member, 6_500}], date: ~D[2026-10-03])

      for e <- [e1, e2],
          do: run!(ctx.member, "UPDATE expenses SET template_id = $1 WHERE id = $2", [t, e])

      assert [[6_500, ~D[2026-10-03]]] = last_logged(t)

      run!(ctx.member, "UPDATE expenses SET deleted_at = now() WHERE id = $1", [e2])
      assert [[6_000, ~D[2026-09-03]]] = last_logged(t)
    end

    test "a private expense can't come from a template", ctx do
      t = template!(ctx.member, ctx.group)
      e = expense!(ctx.member, ctx.group, 500, [{ctx.member, 500}], visibility: "private")

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               run(ctx.member, "UPDATE expenses SET template_id = $1 WHERE id = $2", [t, e])
    end

    test "a default split naming someone outside the group is refused", ctx do
      assert_raise Postgrex.Error, ~r/everyone in a split/, fn ->
        template!(ctx.member, ctx.group, %{
          split: %{"type" => "equal", "entries" => [%{"user_id" => ctx.outsider}]}
        })
      end
    end
  end

  describe "split_overrides" do
    test "admins add and change them; members only read", ctx do
      assert {:ok, o} = override!(ctx.admin, ctx.group, ~D[2026-11-01], ~D[2026-11-30])
      assert {:error, e} = override!(ctx.member, ctx.group, ~D[2027-01-01], nil)
      assert refused?({:error, e})

      assert count_rows(ctx.member, "split_overrides", o) == 1
      assert count_rows(ctx.outsider, "split_overrides", o) == 0

      assert rows(run(ctx.member, "UPDATE split_overrides SET note = 'x' WHERE id = $1", [o])) ==
               0

      assert rows(run(ctx.admin, "UPDATE split_overrides SET note = 'x' WHERE id = $1", [o])) == 1
    end

    test "overlaps on the same bills are refused; other categories and other dates aren't", ctx do
      {:ok, _} =
        override!(ctx.admin, ctx.group, ~D[2026-11-01], ~D[2026-11-30],
          category_id: ctx.utilities
        )

      assert {:error, %Postgrex.Error{postgres: %{hint: "override_overlap"}}} =
               override!(ctx.admin, ctx.group, ~D[2026-11-30], ~D[2026-12-15],
                 category_id: ctx.utilities
               )

      # No category covers every category, so it collides too.
      assert {:error, %Postgrex.Error{postgres: %{hint: "override_overlap"}}} =
               override!(ctx.admin, ctx.group, ~D[2026-11-15], nil)

      assert {:ok, _} =
               override!(ctx.admin, ctx.group, ~D[2026-11-10], ~D[2026-11-20],
                 category_id: ctx.rent
               )

      assert {:ok, _} =
               override!(ctx.admin, ctx.group, ~D[2026-12-01], nil, category_id: ctx.utilities)
    end

    test "a removed one no longer blocks", ctx do
      {:ok, o} = override!(ctx.admin, ctx.group, ~D[2026-11-01], nil)
      run!(ctx.admin, "UPDATE split_overrides SET deleted_at = now() WHERE id = $1", [o])
      assert {:ok, _} = override!(ctx.admin, ctx.group, ~D[2026-11-05], ~D[2026-11-06])
    end
  end

  describe "statement_links" do
    test "members make and revoke them; outsiders can't; a revoked link stays revoked", ctx do
      link!(ctx.member, ctx.group, ctx.admin)
      [[id]] = owner!("SELECT id FROM statement_links WHERE group_id = $1", [ctx.group])

      assert count_rows(ctx.admin, "statement_links", id) == 1
      assert count_rows(ctx.outsider, "statement_links", id) == 0
      assert_raise Postgrex.Error, fn -> link!(ctx.outsider, ctx.group, ctx.admin) end

      assert rows(
               run(ctx.admin, "UPDATE statement_links SET revoked_at = now() WHERE id = $1", [id])
             ) ==
               1

      assert refused?(
               run(ctx.admin, "UPDATE statement_links SET revoked_at = NULL WHERE id = $1", [id])
             )

      assert refused?(
               run(ctx.admin, "UPDATE statement_links SET expires_at = now() WHERE id = $1", [id])
             )
    end

    test "a link lasts 30 days at most and can't be made already revoked", ctx do
      link!(ctx.member, ctx.group, ctx.admin, revoked_at: ~N[2026-10-01 00:00:00])

      [[revoked, days]] =
        owner!(
          "SELECT revoked_at, extract(day FROM expires_at - now() AT TIME ZONE 'utc')::int FROM statement_links"
        )

      assert revoked == nil
      assert days <= 30
    end
  end

  describe "read_statement" do
    setup ctx do
      landlord = counterparty!(ctx.admin, ctx.group, "Landlord")
      third = person()
      join!(third, ctx.group, ctx.admin)

      expense!(
        ctx.admin,
        ctx.group,
        9_000,
        [{ctx.admin, 3_000}, {ctx.member, 3_000}, {third, 3_000}],
        description: "Electric",
        date: ~D[2026-10-05],
        category_id: ctx.utilities
      )

      # Only between admin and third: not on the member's statement.
      expense!(ctx.admin, ctx.group, 2_000, [{ctx.admin, 1_000}, {third, 1_000}],
        description: "Wine",
        date: ~D[2026-10-06]
      )

      # Last month: not on October's statement.
      expense!(ctx.admin, ctx.group, 4_000, [{ctx.admin, 2_000}, {ctx.member, 2_000}],
        description: "September water",
        date: ~D[2026-09-20]
      )

      expense!(ctx.member, ctx.group, 700, [{ctx.member, 700}],
        description: "Secret",
        visibility: "private",
        date: ~D[2026-10-07]
      )

      expense!(
        ctx.admin,
        ctx.group,
        10_000,
        [{ctx.admin, 5_000}, {{:counterparty, landlord}, 5_000}],
        description: "Repairs",
        date: ~D[2026-10-08]
      )

      payment!(ctx.member, ctx.group, ctx.member, ctx.admin, 1_000, date: ~D[2026-10-10])
      Map.merge(ctx, %{landlord: landlord, third: third})
    end

    test "shows only the recipient's own slice of its own month", ctx do
      token = link!(ctx.admin, ctx.group, ctx.member)
      assert {:ok, s} = statement(token)

      assert s["group"] == "Elm Street"
      assert [%{"description" => "Electric", "share_cents" => 3_000}] = s["expenses"]

      assert [%{"amount_cents" => 1_000, "direction" => "paid", "status" => "pending"}] =
               s["payments"]

      refute inspect(s) =~ "Wine"
      refute inspect(s) =~ "Secret"
      refute inspect(s) =~ "Repairs"
      refute inspect(s) =~ "Landlord"

      # Where they stand today counts every month: 3,000 + 2,000 owed to the admin.
      assert [%{"owes" => true, "amount_cents" => 5_000}] = s["standing"]
    end

    test "works for an outside party", ctx do
      token = link!(ctx.member, ctx.group, {:counterparty, ctx.landlord})
      assert {:ok, s} = statement(token)
      assert s["recipient"] == "Landlord"
      assert [%{"description" => "Repairs", "share_cents" => 5_000}] = s["expenses"]
      assert [%{"owes" => true, "amount_cents" => 5_000}] = s["standing"]
    end

    test "expired, revoked, and made-up tokens fail the same way", ctx do
      expired = link!(ctx.admin, ctx.group, ctx.member)
      owner!("UPDATE statement_links SET expires_at = now() - interval '1 minute'")
      revoked = link!(ctx.admin, ctx.group, ctx.member, revoked_at: nil)

      owner!(
        "UPDATE statement_links SET revoked_at = now() WHERE revoked_at IS NULL AND expires_at > now()"
      )

      for token <- [expired, revoked, "made-up", ""] do
        assert {:error, %Postgrex.Error{postgres: %{hint: "invalid_statement", message: msg}}} =
                 statement(token)

        assert msg == "this statement link is not valid"
      end
    end

    test "as nobody, every table refuses to be read", ctx do
      _ = link!(ctx.admin, ctx.group, ctx.member)

      for table <-
            ~w(users profiles groups memberships invites counterparties categories expenses
               expense_shares payments audit_log recurring_templates split_overrides statement_links) do
        assert {:ok, 0} =
                 Repo.as_nobody(fn ->
                   case Repo.query("SELECT count(*) FROM #{table}") do
                     {:ok, %{rows: [[n]]}} -> n
                     {:error, _} -> 0
                   end
                 end),
               "nobody could read #{table}"
      end
    end
  end

  defp count_rows(uid, table, id) do
    [[n]] = run!(uid, "SELECT count(*) FROM #{table} WHERE id = $1", [id])
    n
  end

  defp last_logged(t),
    do:
      owner!("SELECT last_amount_cents, last_logged_on FROM recurring_templates WHERE id = $1", [
        t
      ])
end
