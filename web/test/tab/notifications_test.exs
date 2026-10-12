defmodule Tab.NotificationsTest do
  @moduledoc "Phase 2 test 4: the right emails are queued, and the app works with no mail settings."
  use Tab.DataCase, async: false
  use Oban.Testing, repo: Tab.Repo

  import Swoosh.TestAssertions
  import Tab.AccountsFixtures

  alias Tab.{Accounts, Groups, Ledger}
  alias Tab.Notifications.Worker

  setup do
    priya = user_scope_fixture()
    sam = user_scope_fixture()
    jo = user_scope_fixture()

    for {s, name} <- [{priya, "Priya"}, {sam, "Sam"}, {jo, "Jo"}],
        do: Accounts.update_profile(s, %{display_name: name})

    {:ok, house} = Groups.create_group(priya, %{name: "Elm Street"})

    for s <- [sam, jo] do
      {:ok, {token, _}} = Groups.create_invite(priya, house.id)
      {:ok, _} = Groups.accept_invite(s, token)
    end

    flush_emails()
    %{priya: priya, sam: sam, jo: jo, house: house}
  end

  # Sign-in emails from making the test users.
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp expense(scope, group, ids, opts \\ []) do
    Ledger.create_expense(scope, group.id, %{
      description: "Internet",
      amount_cents: 9_000,
      date: ~D[2026-10-01],
      paid_by: scope.user.id,
      visibility: Keyword.get(opts, :visibility, "shared"),
      split: %{"type" => "equal", "entries" => Enum.map(ids, &%{"user_id" => &1})}
    })
  end

  defp recipients(event) do
    all_enqueued(worker: Worker)
    |> Enum.filter(&(&1.args["event"] == event))
    |> Enum.map(& &1.args["recipient_id"])
    |> Enum.sort()
  end

  test "a new shared expense emails everyone in it except whoever added it", ctx do
    {:ok, _} = expense(ctx.priya, ctx.house, [ctx.priya.user.id, ctx.sam.user.id])
    assert recipients("expense_added") == [ctx.sam.user.id]
  end

  test "a private expense emails nobody", ctx do
    {:ok, _} = expense(ctx.priya, ctx.house, [ctx.priya.user.id], visibility: "private")
    assert all_enqueued(worker: Worker) == []
  end

  test "changing the amount or split emails the split; renaming doesn't", ctx do
    {:ok, e} = expense(ctx.priya, ctx.house, [ctx.priya.user.id, ctx.sam.user.id, ctx.jo.user.id])
    {:ok, _} = Ledger.update_expense(ctx.priya, e.id, %{description: "Wi-Fi"})
    assert recipients("expense_changed") == []

    {:ok, _} = Ledger.update_expense(ctx.priya, e.id, %{amount_cents: 12_000})
    assert recipients("expense_changed") == Enum.sort([ctx.sam.user.id, ctx.jo.user.id])
  end

  test "a pending payment emails the payee; one the payee records emails nobody", ctx do
    pay = fn scope ->
      Ledger.record_payment(scope, ctx.house.id, %{
        from_user_id: ctx.sam.user.id,
        to_user_id: ctx.priya.user.id,
        amount_cents: 1_500,
        date: ~D[2026-10-02],
        method: "venmo"
      })
    end

    {:ok, %{status: "pending"}} = pay.(ctx.sam)
    assert recipients("payment_pending") == [ctx.priya.user.id]

    {:ok, %{status: "confirmed"}} = pay.(ctx.priya)
    assert length(recipients("payment_pending")) == 1
  end

  test "the emails say what happened, as the recipient sees it", ctx do
    {:ok, e} = expense(ctx.priya, ctx.house, [ctx.priya.user.id, ctx.sam.user.id])
    [job] = all_enqueued(worker: Worker)
    assert :ok = perform_job(Worker, job.args)

    assert_email_sent(fn email ->
      assert email.to == [{"", ctx.sam.user.email}]
      assert email.subject == "Priya added Internet ($90.00) in Elm Street"
      assert email.text_body =~ "Your share: $45.00"
      assert email.text_body =~ "/groups/#{ctx.house.id}/expenses/#{e.id}"
    end)
  end

  test "someone who has left by the time the job runs gets nothing", ctx do
    {:ok, _} = expense(ctx.priya, ctx.house, [ctx.priya.user.id, ctx.jo.user.id])
    [job] = all_enqueued(worker: Worker)
    {:ok, _} = Groups.remove_member(ctx.priya, ctx.house.id, ctx.jo.user.id)

    assert :ok = perform_job(Worker, job.args)
    assert_no_email_sent()
  end

  describe "with no mail settings" do
    setup do
      original = Application.get_env(:tab, Tab.Mailer)
      level = Logger.level()
      Application.put_env(:tab, Tab.Mailer, adapter: Swoosh.Adapters.Logger, level: :warning)
      Logger.configure(level: :info)

      on_exit(fn ->
        Application.put_env(:tab, Tab.Mailer, original)
        Logger.configure(level: level)
      end)
    end

    test "notifications are skipped and logged, and the ledger works", ctx do
      {:ok, _} = expense(ctx.priya, ctx.house, [ctx.priya.user.id, ctx.sam.user.id])
      [job] = all_enqueued(worker: Worker)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok = perform_job(Worker, job.args)
        end)

      assert log =~ "skipped a expense_added email" or log =~ "skipped"
      assert {:ok, [_]} = Ledger.balances(ctx.sam, ctx.house.id)
    end
  end
end
