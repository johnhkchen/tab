defmodule Tab.BillingTest do
  @moduledoc """
  Phase 6 plans (docs/specification.md, "Tests that must pass before phase
  7"): self-host untouched, plans worked out from dates, the trial once per
  address, allowances enforced server-side, asking for more, and the billing
  tables' row-level security.
  """
  use TabWeb.ConnCase, async: false
  use Oban.Testing, repo: Tab.Repo

  import Phoenix.LiveViewTest
  import Tab.AccountsFixtures

  alias Tab.{Accounts, Billing, Inbox, Repo}
  alias Tab.Accounts.Scope
  alias Tab.Billing.{Account, MailWorker}
  alias Tab.Inbox.ReadWorker

  @now ~U[2026-10-16 12:00:00Z]

  defp cloud(_ctx) do
    Application.put_env(:tab, :edition, "cloud")
    on_exit(fn -> Application.put_env(:tab, :edition, "self_host") end)
    :ok
  end

  defp read_n(user_id, n, paid? \\ false) do
    for _ <- 1..n, do: Billing.record_read(user_id, nil, paid?, @now)
  end

  describe "self-host" do
    test "no billing rows, no limits, no plans" do
      user = user_fixture()
      assert :ok = Billing.start(user, @now)
      assert Repo.all(Account) == []
      assert Billing.plan(user.id, @now) == %{tier: :self_host}
      assert {:ok, true} = Billing.may_read(user.id, @now)
      refute Billing.signups_full?(@now)
      Billing.record_read(user.id, nil, true, @now)
      assert Repo.aggregate(Tab.Billing.Read, :count) == 0
    end
  end

  describe "on Hosted Tab" do
    setup :cloud

    test "a new account gets 3 months of trial Plus, then Hosted free with nothing lost" do
      user = user_fixture()
      :ok = Billing.start(user, @now)

      assert %{tier: :plus, source: :trial, until: until} = Billing.plan(user.id, @now)
      assert until == ~U[2027-01-16 12:00:00Z]

      after_trial = DateTime.add(until, 1)
      assert %{tier: :free, trial_ended: ^until} = Billing.plan(user.id, after_trial)
      assert {:error, :no_plan} = Billing.may_read(user.id, after_trial)

      # Signing in again changes nothing.
      :ok = Billing.start(user, DateTime.add(@now, 30, :day))
      assert %{until: ^until} = Billing.plan(user.id, @now)
    end

    test "one trial per address, even after deleting the account" do
      user = user_fixture(%{email: "once@example.com"})
      :ok = Billing.start(user, @now)
      {:ok, _} = Accounts.delete_account(Scope.for_user(user))
      assert Repo.get(Account, user.id) == nil

      again = user_fixture(%{email: "ONCE@example.com"})
      :ok = Billing.start(again, @now)
      assert %{tier: :free, trial_ended: nil} = Billing.plan(again.id, @now)
    end

    test "paid Plus outranks the trial, and ends with its paid period" do
      user = user_fixture()
      :ok = Billing.start(user, @now)

      Repo.get!(Account, user.id)
      |> Ecto.Changeset.change(paid_plan: "plus", paid_until: ~U[2027-10-16 12:00:00Z])
      |> Repo.update!()

      assert %{tier: :plus, source: :paid} = Billing.plan(user.id, @now)
      assert Billing.allowance(Billing.plan(user.id, @now)) == 100
      assert %{tier: :free} = Billing.plan(user.id, ~U[2027-10-17 00:00:00Z])
    end

    test "allowances: the 21st trial read and the 101st paid read wait for the 1st" do
      trial = user_fixture()
      :ok = Billing.start(trial, @now)
      read_n(trial.id, 20)
      assert {:error, {:limit, ~D[2026-11-01]}} = Billing.may_read(trial.id, @now)
      assert {:ok, false} = Billing.may_read(trial.id, ~U[2026-11-01 00:10:00Z])

      paid = user_fixture()

      Repo.insert!(%Account{
        user_id: paid.id,
        paid_plan: "plus",
        paid_until: ~U[2027-10-16 00:00:00Z]
      })

      read_n(paid.id, 99, true)
      assert {:ok, true} = Billing.may_read(paid.id, @now)
      read_n(paid.id, 1, true)
      assert {:error, {:limit, _}} = Billing.may_read(paid.id, @now)
    end

    test "the 80% email goes once a month" do
      user = user_fixture()
      :ok = Billing.start(user, @now)
      read_n(user.id, 15)
      assert all_enqueued(worker: MailWorker) == []

      read_n(user.id, 3)

      assert [%{args: %{"kind" => "reading_warning", "used" => 16}}] =
               all_enqueued(worker: MailWorker)
    end

    test "Hosted free reads nothing; trial reads wait behind paid ones", %{} do
      free = user_fixture()
      Repo.insert!(%Account{user_id: free.id})
      scope = Scope.for_user(free)

      {:ok, item} =
        Inbox.upload(scope, %{
          content_type: "application/pdf",
          filename: "b.pdf",
          data: "%PDF-1.4 x"
        })

      [job] = all_enqueued(worker: ReadWorker)
      assert job.priority == 0
      :ok = perform_job(ReadWorker, job.args)
      {:ok, item} = Inbox.get_item(scope, item.id)
      assert item.status == "unreadable"
      assert item.note =~ "Plus"

      trial = user_fixture()
      :ok = Billing.start(trial)
      assert Billing.read_priority(trial.id) == 3

      paid = user_fixture()

      Repo.insert!(%Account{
        user_id: paid.id,
        paid_plan: "plus",
        paid_until: DateTime.add(DateTime.utc_now(:second), 30, :day)
      })

      assert Billing.read_priority(paid.id) == 0
    end

    test "past the allowance, an item waits until the 1st and isn't read" do
      user = user_fixture()
      :ok = Billing.start(user)
      scope = Scope.for_user(user)
      for _ <- 1..20, do: Billing.record_read(user.id, nil, false)

      Req.Test.stub(Tab.Reader, fn _ -> raise "the reader was called" end)

      {:ok, item} =
        Inbox.upload(scope, %{
          content_type: "application/pdf",
          filename: "b.pdf",
          data: "%PDF-1.4 y"
        })

      [job] = all_enqueued(worker: ReadWorker)
      :ok = perform_job(ReadWorker, job.args, priority: job.priority)
      {:ok, item} = Inbox.get_item(scope, item.id)
      assert item.status == "waiting"
      assert item.note =~ "reading paused until"

      first = Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: 1)
      assert_enqueued(worker: ReadWorker, scheduled_at: DateTime.new!(first, ~T[00:05:00]))
    end

    test "the daily sign-up limit counts confirmed accounts" do
      Application.put_env(:tab, :signups_per_day, 2)
      on_exit(fn -> Application.put_env(:tab, :signups_per_day, 50) end)

      for _ <- 1..2, do: Billing.start(user_fixture())
      assert Billing.signups_full?()
    end

    test "a full day sends no link to a new address, and says the same to everyone", %{conn: conn} do
      Application.put_env(:tab, :signups_per_day, 0)
      on_exit(fn -> Application.put_env(:tab, :signups_per_day, 50) end)

      {:ok, lv, _} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        lv
        |> form("#login_form_magic", user: %{email: "brand-new@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "try again tomorrow"
      assert Accounts.get_user_by_email("brand-new@example.com") == nil
    end

    test "asking for more: when, what's asked, and granting", %{} do
      user = user_fixture()
      scope = Scope.for_user(user)
      :ok = Billing.start(user, @now)

      # Not while the trial has months left.
      assert Billing.extension_question(scope, @now) == nil
      late = ~U[2027-01-05 00:00:00Z]
      assert Billing.extension_question(scope, late) == "What do you use Tab for?"

      # Two weeks before the end of the real clock's trial: shift it.
      Repo.get!(Account, user.id)
      |> Ecto.Changeset.change(trial_until: DateTime.add(DateTime.utc_now(:second), 5, :day))
      |> Repo.update!()

      assert {:ok, request} =
               Billing.request_extension(scope, %{"answer" => "Our house", "may_quote" => "true"})

      assert request.question == "What do you use Tab for?"
      assert Billing.request_waiting?(scope)
      assert Billing.extension_question(scope) == nil
      assert {:error, :not_now} = Billing.request_extension(scope, %{"answer" => "again"})

      assert [%{email: email}] = Billing.waiting_requests()
      assert email == user.email

      before = Repo.get!(Account, user.id).trial_until
      assert {:ok, "granted"} = Billing.grant(request.id)
      assert Repo.get!(Account, user.id).trial_until == DateTime.shift(before, month: 6)
      assert [%{args: %{"kind" => "extension_granted"}}] = all_enqueued(worker: MailWorker)
      assert {:error, :not_found} = Billing.grant(request.id)

      # The next time, the second question.
      Repo.get!(Account, user.id)
      |> Ecto.Changeset.change(trial_until: DateTime.add(DateTime.utc_now(:second), -1, :day))
      |> Repo.update!()

      assert Billing.extension_question(scope) =~ "few words we can quote"
    end

    test "admin? needs Hosted Tab and an address in TAB_ADMIN_EMAILS" do
      boss = user_fixture(%{email: "boss@example.com"})
      Application.put_env(:tab, :admin_emails, ["boss@example.com"])
      on_exit(fn -> Application.put_env(:tab, :admin_emails, []) end)

      assert Billing.admin?(Scope.for_user(boss))
      refute Billing.admin?(Scope.for_user(user_fixture()))
      refute Billing.admin?(nil)
    end

    test "the stats count accounts and reads, nothing else" do
      a = user_fixture()
      :ok = Billing.start(a, @now)
      read_n(a.id, 3)

      stats = Billing.stats(@now)
      assert %{accounts: 1, trials: 1, paid_plus: 0, reads_this_month: 3} = stats

      assert Map.keys(stats) |> Enum.sort() ==
               ~w(accounts free mail_today paid_plus paid_pro read_cost_estimate_cents reads_this_month trials)a
    end
  end

  describe "row-level security" do
    import Tab.LedgerSQL

    setup :cloud

    test "billing rows are their owner's to read and nobody's to write" do
      a = user_fixture()
      b = user_fixture()
      :ok = Billing.start(a)
      :ok = Billing.start(b)
      read_n(a.id, 1)

      assert run!(a.id, "SELECT count(*) FROM billing_accounts") == [[1]]
      assert run!(a.id, "SELECT count(*) FROM reads") == [[1]]
      assert run!(b.id, "SELECT count(*) FROM reads") == [[0]]

      refused = fn result ->
        match?(
          {:error, %Postgrex.Error{postgres: %{code: c}}}
          when c in [:insufficient_privilege, :check_violation],
          result
        )
      end

      assert refused.(
               run(
                 a.id,
                 "UPDATE billing_accounts SET paid_plan = 'plus', paid_until = now() + interval '1 year'"
               )
             )

      assert refused.(run(a.id, "INSERT INTO billing_accounts (user_id) VALUES ($1)", [b.id]))
      assert refused.(run(a.id, "INSERT INTO reads (user_id, paid) VALUES ($1, true)", [a.id]))
      assert refused.(run(a.id, "SELECT count(*) FROM trial_emails"))
      assert refused.(run(a.id, "SELECT count(*) FROM paddle_events"))
      assert refused.(run(a.id, "DELETE FROM reads"))

      # A request can only be made waiting, and only as yourself.
      assert refused.(
               run(
                 a.id,
                 "INSERT INTO extension_requests (question, answer, status) VALUES ('q', 'a', 'granted')"
               )
             )

      run!(
        b.id,
        "INSERT INTO extension_requests (question, answer, user_id) VALUES ('q', 'a', $1)",
        [a.id]
      )

      assert run!(a.id, "SELECT count(*) FROM extension_requests") == [[0]]
      assert run!(b.id, "SELECT count(*) FROM extension_requests") == [[1]]

      assert refused.(run(b.id, "UPDATE extension_requests SET status = 'granted'")) or
               match?(
                 {:ok, %{num_rows: 0}},
                 run(b.id, "UPDATE extension_requests SET status = 'granted'")
               )
    end
  end
end
