defmodule Tab.Accounts.DeleteAccountTest do
  @moduledoc """
  Deleting an account (docs/specification.md, "Deleting an account"): the
  person and their private data go, the shared ledger stays, and housemates'
  balances don't move.
  """
  use TabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tab.AccountsFixtures

  alias Tab.{Accounts, Groups, Ledger, OAuth, Repo}
  alias Tab.Accounts.{Scope, User}

  setup do
    priya = user_fixture()
    marcus = user_fixture()
    ps = Scope.for_user(priya)
    ms = Scope.for_user(marcus)

    Accounts.update_profile(ps, %{
      display_name: "Priya",
      payment_methods: [%{"kind" => "venmo", "handle" => "@p"}]
    })

    Accounts.update_profile(ms, %{display_name: "Marcus"})

    {:ok, house} = Groups.create_group(ps, %{name: "Elm Street"})
    {:ok, {token, _}} = Groups.create_invite(ps, house.id)
    {:ok, _} = Groups.accept_invite(ms, token)
    {:ok, solo} = Groups.create_group(ps, %{name: "Just me"})

    both = %{
      "type" => "equal",
      "entries" => [%{"user_id" => priya.id}, %{"user_id" => marcus.id}]
    }

    {:ok, shared} =
      Ledger.create_expense(ps, house.id, %{
        description: "Internet",
        amount_cents: 6_000,
        date: ~D[2026-10-01],
        paid_by: priya.id,
        split: both
      })

    {:ok, private} =
      Ledger.create_expense(ps, house.id, %{
        description: "My own",
        amount_cents: 900,
        date: ~D[2026-10-02],
        paid_by: priya.id,
        visibility: "private",
        split: %{"type" => "equal", "entries" => [%{"user_id" => priya.id}]}
      })

    {:ok, _} =
      Ledger.record_payment(ms, house.id, %{
        from_user_id: marcus.id,
        to_user_id: priya.id,
        amount_cents: 1_000,
        date: ~D[2026-10-03],
        method: "venmo"
      })

    {:ok, _address} = Tab.Inbox.address(ps, house.id)

    {:ok, _item} =
      Tab.Inbox.upload(ps, %{
        content_type: "application/pdf",
        filename: "b.pdf",
        data: "%PDF-1.4 bill"
      })

    %{
      priya: priya,
      marcus: marcus,
      ps: ps,
      ms: ms,
      house: house,
      solo: solo,
      shared: shared,
      private: private
    }
  end

  defp count(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()
  defp dump(id), do: Ecto.UUID.dump!(id)

  test "the person and their private data go; the shared ledger stays", ctx do
    {:ok, before} = Ledger.balances(ctx.ms, ctx.house.id)
    session = Accounts.generate_user_session_token(ctx.priya)
    email = ctx.priya.email

    assert {:ok, [_ | _]} = Accounts.delete_account(ctx.ps)

    # Marcus's view of the money doesn't move.
    assert {:ok, ^before} = Ledger.balances(ctx.ms, ctx.house.id)
    {:ok, expenses} = Ledger.list_expenses(ctx.ms, ctx.house.id)
    assert Enum.map(expenses, & &1.id) == [ctx.shared.id]

    # Priya can't sign in, and her address is free.
    assert Accounts.get_user_by_session_token(session) == nil
    assert Accounts.get_user_by_email(email) == nil
    user = Repo.get!(User, ctx.priya.id)
    assert user.email =~ "@deleted.invalid"
    assert user.hashed_password == nil

    # Her private expense, its shares and audit entries, and her bills are gone.
    pid = dump(ctx.priya.id)
    assert count("SELECT count(*) FROM expenses WHERE id = $1", [dump(ctx.private.id)]) == 0

    assert count("SELECT count(*) FROM expense_shares WHERE expense_id = $1", [
             dump(ctx.private.id)
           ]) == 0

    assert count("SELECT count(*) FROM audit_log WHERE private_owner_id = $1", [pid]) == 0
    assert count("SELECT count(*) FROM audit_log WHERE row_id = $1", [dump(ctx.shared.id)]) > 0

    for table <- ~w(documents pending_items forwarding_addresses oauth_connections users_tokens) do
      assert count("SELECT count(*) FROM #{table} WHERE user_id = $1", [pid]) == 0, table
    end

    # The name that stays, and nothing else.
    [[name, methods]] =
      Repo.query!("SELECT display_name, payment_methods FROM profiles WHERE user_id = $1", [pid]).rows

    assert {name, methods} == {"Former member", []}

    # She left every group; Marcus runs the house; her solo group is archived.
    {:ok, members} = Groups.list_members(ctx.ms, ctx.house.id)
    assert [%{user_id: mid, role: "admin"}] = members
    assert mid == ctx.marcus.id

    [[archived]] =
      Repo.query!("SELECT deleted_at FROM groups WHERE id = $1", [dump(ctx.solo.id)]).rows

    assert archived
  end

  test "Claude connections stop working", ctx do
    client =
      Repo.insert!(%OAuth.Client{
        client_id: "tab_c_test",
        kind: "dcr",
        name: "Claude Code",
        redirect_uris: ["http://localhost/cb"]
      })

    {:ok, _} =
      Tab.DBError.as_user(ctx.ps, fn ->
        Repo.insert(%OAuth.Connection{
          id: Ecto.UUID.generate(),
          client_id: client.id,
          scopes: ["tab:read"]
        })
      end)

    assert {:ok, _} = Accounts.delete_account(ctx.ps)
    assert count("SELECT count(*) FROM oauth_connections", []) == 0
  end

  test "nobody but the owner connection can call it, and the audit log stays append-only", ctx do
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Tab.LedgerSQL.run(ctx.marcus.id, "SELECT ledger.forget_user($1)", [ctx.priya.id])

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.query!("DELETE FROM audit_log WHERE row_id = $1", [dump(ctx.shared.id)])
    end

    # Forgetting one person doesn't open the log for anyone else's entries.
    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.transact(fn ->
        Repo.query!("SELECT set_config('ledger.forgetting', $1, true)", [ctx.priya.id])
        Repo.query!("DELETE FROM audit_log WHERE row_id = $1", [dump(ctx.shared.id)])
        {:ok, nil}
      end)
    end
  end

  test "from the You page, only after typing DELETE", %{conn: conn, priya: priya} do
    conn = log_in_user(conn, priya)
    {:ok, lv, _} = live(conn, ~p"/profile")

    html = lv |> form("#delete_form", %{"confirm" => "delete"}) |> render_submit()
    assert html =~ "Type DELETE"
    assert Accounts.get_user_by_email(priya.email)

    assert {:error, {:redirect, %{to: "/"}}} =
             lv |> form("#delete_form", %{"confirm" => "DELETE"}) |> render_submit()

    assert Accounts.get_user_by_email(priya.email) == nil
  end
end
