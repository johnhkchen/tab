defmodule TabWeb.GroupPagesTest do
  @moduledoc "Each page's main path and its refusals (docs/specification.md, phase 2 test 1)."
  use TabWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tab.AccountsFixtures

  alias Tab.{Accounts, Groups, Ledger}

  setup :register_and_log_in_user

  setup %{scope: scope} do
    Accounts.update_profile(scope, %{display_name: "Priya"})
    {:ok, group} = Groups.create_group(scope, %{name: "Elm Street"})

    sam = user_fixture()
    sam_scope = Accounts.Scope.for_user(sam)
    Accounts.update_profile(sam_scope, %{display_name: "Sam"})
    {:ok, {token, _}} = Groups.create_invite(scope, group.id)
    {:ok, _} = Groups.accept_invite(sam_scope, token)

    %{group: group, sam: sam, sam_scope: sam_scope}
  end

  defp as(conn, user), do: conn |> recycle() |> log_in_user(user)

  describe "your groups" do
    test "lists groups with where you stand, and starts new ones", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/groups")
      assert html =~ "Elm Street"
      assert html =~ "All even"

      {:ok, _lv, html} =
        lv
        |> form("#new_group", group: %{name: "Ski trip"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Ski trip"
      assert html =~ "Nothing yet"
    end

    test "says what's wrong with a blank name", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/groups")

      assert lv |> form("#new_group", group: %{name: "  "}) |> render_submit() =~
               "can&#39;t be blank"
    end
  end

  describe "a group's pages refuse outsiders with a plain 404" do
    test "without leaking the group's name", %{conn: conn, group: group} do
      outsider = user_fixture()
      conn = as(conn, outsider)

      for path <- [
            ~p"/groups/#{group}",
            ~p"/groups/#{group}/members",
            ~p"/groups/#{group}/settle",
            ~p"/groups/#{group}/expenses/new"
          ] do
        {404, _, body} = assert_error_sent(404, fn -> get(conn, path) end)
        refute body =~ "Elm Street"
      end

      assert_error_sent 404, fn -> get(conn, ~p"/groups/not-a-uuid") end
    end

    test "and someone else's private expense is a 404 too", %{
      conn: conn,
      group: group,
      sam_scope: sam_scope,
      sam: sam
    } do
      {:ok, e} =
        Ledger.create_expense(sam_scope, group.id, %{
          description: "Sam's secret",
          amount_cents: 500,
          date: ~D[2026-10-01],
          paid_by: sam.id,
          visibility: "private",
          split: %{"type" => "equal", "entries" => [%{"user_id" => sam.id}]}
        })

      {404, _, body} =
        assert_error_sent(404, fn -> get(conn, ~p"/groups/#{group}/expenses/#{e}") end)

      refute body =~ "Sam&#39;s secret"
    end
  end

  describe "adding an expense" do
    test "shows each share as you type, then saves", %{conn: conn, group: group} do
      {:ok, lv, _} = live(conn, ~p"/groups/#{group}/expenses/new")

      html =
        lv
        |> form("#expense_form", expense: %{description: "Internet", amount: "100.01"})
        |> render_change()

      assert html =~ "$50.01"
      assert html =~ "$50.00"

      {:ok, _lv, html} =
        lv
        |> form("#expense_form", expense: %{description: "Internet", amount: "100.01"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Internet"
      assert html =~ "added it."
    end

    test "a split that doesn't add up says so and saves nothing", %{
      conn: conn,
      group: group,
      user: me,
      sam: sam
    } do
      {:ok, lv, _} = live(conn, ~p"/groups/#{group}/expenses/new")

      lv
      |> form("#expense_form",
        expense: %{description: "Rent", amount: "100", split_type: "exact"}
      )
      |> render_change()

      html =
        lv
        |> form("#expense_form",
          expense: %{description: "Rent", amount: "100", split_type: "exact"},
          value: %{"user:#{me.id}" => "60", "user:#{sam.id}" => "30"}
        )
        |> render_submit()

      assert html =~ "exact amounts add up to 9000 cents, not 10000"
      assert {:ok, []} = Ledger.list_expenses(Accounts.Scope.for_user(me), group.id)
    end

    test "a private expense stays out of the split", %{conn: conn, group: group} do
      {:ok, lv, _} = live(conn, ~p"/groups/#{group}/expenses/new")

      {:ok, _, html} =
        lv
        |> form("#expense_form",
          expense: %{description: "Haircut", amount: "30", private: "true"}
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Only you can see this"
    end

    test "only the creator or an admin gets Edit; the group archived means no adding", %{
      conn: conn,
      group: group,
      scope: scope,
      user: me,
      sam: sam
    } do
      {:ok, e} =
        Ledger.create_expense(scope, group.id, %{
          description: "Rent",
          amount_cents: 2_000,
          date: ~D[2026-10-01],
          paid_by: me.id,
          split: %{
            "type" => "equal",
            "entries" => [%{"user_id" => me.id}, %{"user_id" => sam.id}]
          }
        })

      {:ok, _, html} = live(as(conn, sam), ~p"/groups/#{group}/expenses/#{e}")
      refute html =~ "Edit"

      {:ok, _, html} = live(conn, ~p"/groups/#{group}/expenses/#{e}")
      assert html =~ "Edit"

      {:ok, _} = Groups.archive_group(scope, group.id)
      assert_error_sent 404, fn -> get(conn, ~p"/groups/#{group}/expenses/new") end
      {:ok, _, html} = live(conn, ~p"/groups/#{group}")
      assert html =~ "This group is archived"
      refute html =~ "Add expense"
    end
  end

  describe "editing" do
    test "re-splits, marks it edited, and shows the change in history", %{
      conn: conn,
      group: group,
      scope: scope,
      user: me,
      sam: sam
    } do
      {:ok, e} =
        Ledger.create_expense(scope, group.id, %{
          description: "Rent",
          amount_cents: 2_000,
          date: ~D[2026-10-01],
          paid_by: me.id,
          split: %{
            "type" => "equal",
            "entries" => [%{"user_id" => me.id}, %{"user_id" => sam.id}]
          }
        })

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/expenses/#{e}/edit")
      assert html =~ "20.00"

      {:ok, _, html} =
        lv
        |> form("#expense_form", expense: %{amount: "30"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "$15.00"
      assert html =~ "changed the amount"
      assert html =~ "Last edited"
    end
  end

  describe "settling up" do
    setup %{scope: scope, group: group, user: me, sam: sam} do
      {:ok, _} =
        Ledger.create_expense(scope, group.id, %{
          description: "Groceries",
          amount_cents: 4_000,
          date: ~D[2026-10-01],
          paid_by: me.id,
          split: %{
            "type" => "equal",
            "entries" => [%{"user_id" => me.id}, %{"user_id" => sam.id}]
          }
        })

      :ok
    end

    test "Sam records a payment; it waits for Priya, who confirms it", %{
      conn: conn,
      group: group,
      user: me,
      sam: sam
    } do
      sam_conn = as(conn, sam)
      {:ok, lv, html} = live(sam_conn, ~p"/groups/#{group}/settle")
      assert html =~ ~r/<strong>You<\/strong>\s*pay\s*<strong>Priya<\/strong>/
      assert html =~ "$20.00"

      html =
        lv
        |> form("#payment_form",
          payment: %{from: "user:#{sam.id}", to: "user:#{me.id}", amount: "15", method: "venmo"}
        )
        |> render_submit()

      assert html =~ "It counts once Priya confirms it arrived."
      assert html =~ "Waiting for Priya"

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}")
      assert html =~ "Did this arrive?"
      [payment] = Ledger.pending_for_me(Accounts.Scope.for_user(me), group.id) |> elem(1)

      html = lv |> element("#pending-#{payment.id} button", "Yes, got it") |> render_click()
      assert html =~ "Marked as arrived."
      assert html =~ "$5.00"
    end

    test "a payee's payment handles show to whoever pays them", %{
      conn: conn,
      group: group,
      scope: scope,
      sam: sam
    } do
      {:ok, _} =
        Accounts.update_profile(scope, %{
          payment_methods: [%{"kind" => "venmo", "handle" => "@priya"}]
        })

      {:ok, _, html} = live(as(conn, sam), ~p"/groups/#{group}")
      assert html =~ "Pay them by Venmo @priya"
    end
  end

  describe "people" do
    test "an admin makes an invite link; someone joins with it once", %{conn: conn, group: group} do
      {:ok, lv, _} = live(conn, ~p"/groups/#{group}/members")
      html = lv |> element("button", "Make an invite link") |> render_click()
      [_, token] = Regex.run(~r{/join/([A-Za-z0-9_-]+)}, html)

      newcomer = user_fixture()
      {:ok, lv, html} = live(as(conn, newcomer), ~p"/join/#{token}")
      assert html =~ "You&#39;re invited"
      refute html =~ "Elm Street"

      {:ok, _, html} =
        lv |> element("#join") |> render_click() |> follow_redirect(as(conn, newcomer))

      assert html =~ "Elm Street"

      {:ok, lv, _} = live(as(conn, user_fixture()), ~p"/join/#{token}")
      assert lv |> element("#join") |> render_click() =~ "doesn&#39;t work any more"
    end

    test "opening an invite link signed out asks you to sign in first", %{
      group: group,
      scope: scope
    } do
      {:ok, {token, _}} = Groups.create_invite(scope, group.id)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/join/#{token}")
    end

    test "members can't make invite links or remove people", %{conn: conn, group: group, sam: sam} do
      {:ok, _, html} = live(as(conn, sam), ~p"/groups/#{group}/members")
      refute html =~ "Make an invite link"
      refute html =~ "Remove them"
    end

    test "you can't leave while you owe money", %{
      conn: conn,
      group: group,
      scope: scope,
      user: me,
      sam: sam
    } do
      {:ok, _} =
        Ledger.create_expense(scope, group.id, %{
          description: "Rent",
          amount_cents: 2_000,
          date: ~D[2026-10-01],
          paid_by: me.id,
          split: %{
            "type" => "equal",
            "entries" => [%{"user_id" => me.id}, %{"user_id" => sam.id}]
          }
        })

      {:ok, lv, _} = live(as(conn, sam), ~p"/groups/#{group}/members")
      assert lv |> element("button", "Leave the group") |> render_click() =~ "Settle up first"
    end

    test "admins see a warning before archiving a group with money owed", %{
      conn: conn,
      group: group,
      scope: scope,
      user: me,
      sam: sam
    } do
      {:ok, _, html} = live(conn, ~p"/groups/#{group}/members")
      refute html =~ "still owe money"

      {:ok, _} =
        Ledger.create_expense(scope, group.id, %{
          description: "Rent",
          amount_cents: 2_000,
          date: ~D[2026-10-01],
          paid_by: me.id,
          split: %{
            "type" => "equal",
            "entries" => [%{"user_id" => me.id}, %{"user_id" => sam.id}]
          }
        })

      {:ok, _, html} = live(conn, ~p"/groups/#{group}/members")
      assert html =~ "still owe money"
    end
  end

  describe "you" do
    test "saves your name and how to pay you", %{conn: conn, group: group, sam: sam} do
      {:ok, lv, _} = live(conn, ~p"/profile")
      lv |> element("button", "Add a way to pay you") |> render_click()

      html =
        lv
        |> form("#profile_form",
          profile: %{display_name: "Priya K"},
          methods: %{"0" => %{kind: "zelle", handle: "priya@example.com"}}
        )
        |> render_submit()

      assert html =~ "Saved."

      {:ok, _, html} = live(as(conn, sam), ~p"/groups/#{group}/members")
      assert html =~ "Priya K"
      assert html =~ "Zelle priya@example.com"
    end
  end

  describe "first sign-in" do
    test "asks for a name, then goes where you were headed", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/welcome?next=/profile")

      {:ok, _, html} =
        lv
        |> form("#welcome_form", profile: %{display_name: "P"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/profile")

      assert html =~ "How to pay you"
    end

    test "won't send you off the site", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/welcome?next=//evil.example")

      assert {:error, {:live_redirect, %{to: "/groups"}}} =
               lv |> form("#welcome_form", profile: %{display_name: "P"}) |> render_submit()
    end
  end
end
