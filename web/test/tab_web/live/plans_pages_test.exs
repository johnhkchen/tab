defmodule TabWeb.PlansPagesTest do
  @moduledoc """
  Phase 6 pages: Plans, the admin page, and the plan notes on the You page
  and Bills to check. Off on self-host; the admin page shows no ledger data.
  """
  use TabWeb.ConnCase, async: false
  use Oban.Testing, repo: Tab.Repo

  import Phoenix.LiveViewTest
  import Tab.AccountsFixtures

  alias Tab.{Billing, Groups, Ledger, Repo}
  alias Tab.Accounts.Scope
  alias Tab.Billing.{Account, Paddle}

  defp cloud(_) do
    Application.put_env(:tab, :edition, "cloud")
    on_exit(fn -> Application.put_env(:tab, :edition, "self_host") end)
    :ok
  end

  defp signed_in(conn, user), do: log_in_user(conn, user)

  test "self-host: no Plans, no Admin, no plan line", %{conn: conn} do
    user = user_fixture()
    conn = signed_in(conn, user)
    assert_raise TabWeb.GroupData.NotFound, fn -> live(conn, ~p"/plans") end
    assert_raise TabWeb.GroupData.NotFound, fn -> live(conn, ~p"/admin") end
    {:ok, _lv, html} = live(conn, ~p"/profile")
    refute html =~ "plan-line"
  end

  describe "on Hosted Tab" do
    setup :cloud

    test "a trial: days left, reading used, Buy Plus", %{conn: conn} do
      user = user_fixture()
      :ok = Billing.start(user)
      Billing.record_read(user.id, nil, false)

      {:ok, lv, html} = live(signed_in(conn, user), ~p"/plans")
      assert html =~ "Trial Plus"
      assert html =~ "days left"
      assert html =~ "Tab read 1 of your 20 bills this month"
      assert has_element?(lv, "#buy-plus[data-price='pri_plus'][data-user='#{user.id}']")
      refute has_element?(lv, "#ask")

      {:ok, _lv, you} = live(signed_in(build_conn(), user), ~p"/profile")
      assert you =~ "trying Plus until"
    end

    test "near the end of a trial: ask for more, then wait", %{conn: conn} do
      user = user_fixture()
      :ok = Billing.start(user)

      Repo.get!(Account, user.id)
      |> Ecto.Changeset.change(trial_until: DateTime.add(DateTime.utc_now(:second), 3, :day))
      |> Repo.update!()

      {:ok, lv, html} = live(signed_in(conn, user), ~p"/plans")
      assert html =~ "What do you use Tab for?"

      html =
        lv
        |> form("#ask_form", %{"answer" => "Our house of four", "may_quote" => "true"})
        |> render_submit()

      assert html =~ "Thanks for writing"
      assert has_element?(lv, "#waiting")
      refute has_element?(lv, "#ask")
    end

    test "Hosted free: no reading, said up front on Bills to check", %{conn: conn} do
      user = user_fixture()
      Repo.insert!(%Account{user_id: user.id})
      conn = signed_in(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/plans")
      assert html =~ "Hosted free"
      assert html =~ "Tab reads bills on Plus"

      {:ok, _lv, inbox} = live(conn, ~p"/inbox")
      assert inbox =~ "Tab reads bills on Plus"
    end

    test "paid Plus: no Buy card, and Manage billing opens Paddle's portal", %{conn: conn} do
      user = user_fixture()

      Repo.insert!(%Account{
        user_id: user.id,
        paid_plan: "plus",
        paid_until: DateTime.add(DateTime.utc_now(:second), 300, :day),
        paddle_customer_id: "ctm_9"
      })

      Req.Test.stub(Paddle, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"urls" => %{"general" => %{"overview" => "https://portal.example/ctm_9"}}}
        })
      end)

      {:ok, lv, html} = live(signed_in(conn, user), ~p"/plans")
      assert html =~ "Plus, paid through"
      refute has_element?(lv, "#buy")

      assert {:error, {:redirect, %{to: "https://portal.example/ctm_9"}}} =
               lv |> element("#portal") |> render_click()
    end

    test "admin: only for TAB_ADMIN_EMAILS; grants; never shows ledger data", %{conn: conn} do
      boss = user_fixture(%{email: "boss@example.com"})
      Application.put_env(:tab, :admin_emails, ["boss@example.com"])
      on_exit(fn -> Application.put_env(:tab, :admin_emails, []) end)

      someone = user_fixture()
      scope = Scope.for_user(someone)
      :ok = Billing.start(someone)
      {:ok, group} = Groups.create_group(scope, %{name: "Secret Street"})

      {:ok, _} =
        Ledger.create_expense(scope, group.id, %{
          description: "Secret pizza",
          amount_cents: 1_234,
          date: ~D[2026-10-10],
          paid_by: someone.id,
          split: %{"type" => "equal", "entries" => [%{"user_id" => someone.id}]}
        })

      Repo.get!(Account, someone.id)
      |> Ecto.Changeset.change(trial_until: DateTime.add(DateTime.utc_now(:second), 2, :day))
      |> Repo.update!()

      {:ok, request} = Billing.request_extension(scope, %{"answer" => "Splitting rent"})

      assert_raise TabWeb.GroupData.NotFound, fn -> live(signed_in(conn, someone), ~p"/admin") end

      {:ok, lv, html} = live(signed_in(build_conn(), boss), ~p"/admin")
      assert html =~ "Splitting rent"
      assert html =~ someone.email
      refute html =~ "Secret pizza"
      refute html =~ "Secret Street"

      html = lv |> element("#grant-#{request.id}") |> render_click()
      assert html =~ "Granted"
      assert has_element?(lv, "#no-requests")

      assert [%{args: %{"kind" => "extension_granted"}}] =
               all_enqueued(worker: Tab.Billing.MailWorker)
    end
  end
end
