defmodule TabWeb.InboxPagesTest do
  @moduledoc """
  Phase 4 pages: adding a bill, checking it beside the original, saving it
  through the add-expense form (kept or deleted), dropping it, the forwarding
  page, digest days, and nobody else seeing any of it.
  """
  use TabWeb.ConnCase, async: false
  use Oban.Testing, repo: Tab.Repo

  import Phoenix.LiveViewTest
  import Tab.AccountsFixtures

  alias Tab.{Accounts, Bills, Groups, Inbox, Ledger, Repo}
  alias Tab.Bills.Suggest
  alias Tab.Inbox.{Item, Message, ReadWorker}

  setup :register_and_log_in_user

  setup %{scope: scope} do
    Accounts.update_profile(scope, %{display_name: "Priya"})
    {:ok, group} = Groups.create_group(scope, %{name: "Elm Street"})
    sam = user_fixture()
    sam_scope = Accounts.Scope.for_user(sam)
    {:ok, {token, _}} = Groups.create_invite(scope, group.id)
    {:ok, _} = Groups.accept_invite(sam_scope, token)
    %{group: group, sam: sam, sam_scope: sam_scope}
  end

  defp as(conn, user), do: conn |> recycle() |> log_in_user(user)

  defp read_bill!(scope, fields, data \\ "%PDF-1.4 bill") do
    {:ok, item} =
      Inbox.upload(scope, %{content_type: "application/pdf", filename: "bill.pdf", data: data})

    Req.Test.stub(Tab.Reader, &Req.Test.json(&1, fields))
    :ok = perform_job(ReadWorker, %{item_id: item.id, user_id: scope.user.id})
    item
  end

  @electric %{
    "doc_type" => "utility",
    "merchant" => "PG&E",
    "total_cents" => 8_420,
    "date" => "2026-10-03",
    "period_start" => "2026-09-02",
    "period_end" => "2026-10-01"
  }

  test "adding a bill from the page", %{conn: conn} = ctx do
    {:ok, lv, html} = live(conn, ~p"/inbox")
    assert html =~ "Nothing to check."

    bill =
      file_input(lv, "#upload_form", :bills, [
        %{name: "bill.pdf", content: "%PDF-1.4 x", type: "application/pdf"}
      ])

    render_upload(bill, "bill.pdf")

    assert render(lv) =~ "Reading it"
    assert [%Item{status: "reading"}] = Repo.all(Item)
    _ = ctx
  end

  test "check a read bill and save it; the original goes, a note stays", %{conn: conn} = ctx do
    item = read_bill!(ctx.scope, @electric)

    {:ok, _lv, html} = live(conn, ~p"/inbox")
    assert html =~ "PG&amp;E"
    assert html =~ "$84.20"

    {:ok, lv, html} = live(conn, ~p"/inbox/#{item}")
    assert html =~ "What Tab read"
    assert html =~ "2026-09-02 to 2026-10-01"

    {:ok, form, html} =
      lv
      |> form("#group_form", group_id: ctx.group.id)
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "From the bill you sent"
    assert html =~ ~s(value="84.20")
    assert html =~ ~s(value="PG&amp;E")
    assert html =~ ~s(value="2026-09-02")
    # Utilities, from the bill's type.
    assert html =~ "Utilities"

    # Before saving, its owner can open the original.
    [doc] = Repo.all(Tab.Inbox.Document)
    resp = get(conn, ~p"/documents/#{doc.id}")
    assert response(resp, 200) == "%PDF-1.4 bill"
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]

    {:ok, _show, html} =
      form
      |> form("#expense_form")
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "What arrived about this bill"
    assert Repo.get!(Item, item.id).status == "confirmed"

    # After saving, nobody can open it, Sam included: only the note stays.
    assert response(get(as(conn, ctx.sam), ~p"/documents/#{doc.id}"), 404)
    assert response(get(as(conn, ctx.user), ~p"/documents/#{doc.id}"), 404)
  end

  test "a bill matching a template fills in its split and offers no new bill",
       %{conn: conn} = ctx do
    {:ok, t} =
      Bills.create_template(ctx.scope, ctx.group.id, %{
        name: "PG&E",
        default_split: Suggest.equal([{:user, ctx.user.id}, {:user, ctx.sam.id}])
      })

    item = read_bill!(ctx.scope, @electric)
    assert Repo.get!(Item, item.id).template_id == t.id

    {:ok, _lv, html} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?item=#{item.id}")
    refute html =~ "Treat bills from"
    assert html =~ ~s(value="84.20")
  end

  test "a first bill from a sender can become a bill", %{conn: conn} = ctx do
    item = read_bill!(ctx.scope, @electric)

    Repo.update_all(Item,
      set: [
        proposal: Map.put(Repo.get!(Item, item.id).proposal, "names", ["PG&E", "pge.com"])
      ]
    )

    {:ok, lv, html} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?item=#{item.id}")
    assert html =~ "Treat bills from PG&amp;E as a bill"

    lv |> form("#expense_form", expense: %{new_bill: "true"}) |> render_submit()
    {:ok, [t]} = Bills.list_templates(ctx.scope, ctx.group.id)
    assert {t.name, t.aliases} == {"PG&E", ["pge.com"]}
  end

  test "a past-due bill with a carried balance fills in this period, and the rest is one tap away",
       %{conn: conn} = ctx do
    item =
      read_bill!(
        ctx.scope,
        Map.merge(@electric, %{
          "total_cents" => 31_240,
          "previous_cents" => 12_390,
          "past_due" => true
        })
      )

    {:ok, _, html} = live(conn, ~p"/inbox")
    assert html =~ "Past due"

    {:ok, lv, html} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?item=#{item.id}")
    assert html =~ ~s(value="188.50")
    assert html =~ "past due"
    assert html =~ "$123.90"
    assert html =~ "from an earlier bill"

    # Left at 0 it saves this period only.
    assert lv |> element("#expense_carried") |> render() =~ ~s(value="0.00")
    html = lv |> element("button[phx-click=add_carried]") |> render_click()
    assert html =~ ~s(value="123.90")

    lv |> form("#expense_form", expense: %{carried: "nope"}) |> render_submit()
    assert render(lv) =~ "type an amount, like 12.50, or 0"

    {:ok, _, _} =
      lv
      |> form("#expense_form", expense: %{carried: "123.90"})
      |> render_submit()
      |> follow_redirect(conn)

    {:ok, [expense]} = Ledger.list_expenses(ctx.scope, ctx.group.id)
    assert expense.amount_cents == 31_240
  end

  test "late bills show on the Bills page", %{conn: conn} = ctx do
    {:ok, t} =
      Bills.create_template(ctx.scope, ctx.group.id, %{
        name: "Water",
        default_split: Suggest.equal([{:user, ctx.user.id}, {:user, ctx.sam.id}])
      })

    {:ok, _} =
      Ledger.create_expense(ctx.scope, ctx.group.id, %{
        description: "Water",
        amount_cents: 3_000,
        date: Date.add(Date.utc_today(), -45),
        paid_by: ctx.user.id,
        split: t.default_split,
        template_id: t.id
      })

    {:ok, _, html} = live(conn, ~p"/groups/#{ctx.group}/bills")
    assert html =~ "Late"
    assert html =~ "check that it was paid"
  end

  test "two emails about one bill show as one, and the expense keeps a note of both",
       %{conn: conn} = ctx do
    email = fn subject, date, body ->
      "From: Priya <priya@gmail.test>\r\nSubject: Fwd: #{subject}\r\nContent-Type: text/plain\r\n\r\n" <>
        "---------- Forwarded message ---------\r\nFrom: <noreply@sfwater.org>\r\nDate: #{date}\r\n" <>
        "Subject: #{subject}\r\n\r\n#{body}\r\n"
    end

    arrive = fn raw, fields ->
      {:ok, item} =
        Inbox.add(ctx.scope, %{
          kind: "email",
          content_type: "message/rfc822",
          data: raw,
          source: "email",
          group_id: ctx.group.id
        })

      Req.Test.stub(Tab.Reader, &Req.Test.json(&1, fields))
      :ok = perform_job(ReadWorker, %{item_id: item.id, user_id: ctx.user.id})
      item
    end

    water = %{
      "doc_type" => "utility",
      "merchant" => "SFPUC",
      "total_cents" => 4_210,
      "due_on" => "2026-10-08"
    }

    item =
      arrive.(
        email.("Your New Water Bill!", "Thu, Sep 24, 2026 at 7:28 PM", "Due $42.10"),
        Map.put(water, "kind", "notice")
      )

    arrive.(
      email.("Autopay scheduled", "Fri, Oct 2, 2026 at 9:00 AM", "We'll take $42.10 on Oct 8"),
      water
      |> Map.merge(%{"kind" => "autopay_scheduled", "due_on" => nil, "paid_on" => "2026-10-08"})
    )

    {:ok, _, html} = live(conn, ~p"/inbox")
    assert html =~ "2 documents"

    {:ok, _, html} = live(conn, ~p"/inbox/#{item}")
    assert html =~ "Bill is ready"
    assert html =~ "Autopay scheduled"

    {:ok, form, _} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?item=#{item.id}")
    {:ok, _, html} = form |> form("#expense_form") |> render_submit() |> follow_redirect(conn)

    assert html =~ "What arrived about this bill"
    assert html =~ "Autopay scheduled"
    assert html =~ "Copy search"
    assert html =~ "from:(noreply@sfwater.org)"
  end

  test "the Bills page keeps aliases and forwarders", %{conn: conn} = ctx do
    {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/bills")

    lv
    |> form("#bill_form", bill: %{name: "Water", aliases: "SFPUC, sfwater.org, , sfpuc"})
    |> render_submit()

    {:ok, [t]} = Bills.list_templates(ctx.scope, ctx.group.id)
    assert t.aliases == ["SFPUC", "sfwater.org"]
    assert render(lv) =~ "Also called SFPUC, sfwater.org"

    html = lv |> form("#forwarder_form", address: "Landlord@Rentals.test") |> render_submit()
    assert html =~ "landlord@rentals.test"

    html = lv |> form("#forwarder_form", address: "nope") |> render_submit()
    assert html =~ "type an email address"

    html = lv |> element("#forwarders button", "Remove") |> render_click()
    refute html =~ "landlord@rentals.test"
  end

  test "put two bills together, then split one back out, from the bill page",
       %{conn: conn} = ctx do
    a =
      read_bill!(
        ctx.scope,
        %{@electric | "merchant" => "SFPUC", "total_cents" => 5_000},
        "%PDF-1.4 a"
      )

    b =
      read_bill!(
        ctx.scope,
        %{@electric | "merchant" => "Hetch Hetchy", "total_cents" => 5_100},
        "%PDF-1.4 b"
      )

    {:ok, lv, html} = live(conn, ~p"/inbox/#{b}")
    assert html =~ "Same bill as another?"

    {:ok, lv, html} =
      lv |> form("#join_form", target: a.id) |> render_submit() |> follow_redirect(conn)

    assert html =~ "Put together."
    assert html =~ "Not part of this bill"

    {:ok, item} = Inbox.get_item(ctx.scope, a.id)
    second = List.last(item.documents)
    html = lv |> element("#doc-#{second.id} button", "Not part of this bill") |> render_click()
    assert html =~ "its own bill to check"
    assert {:ok, [_, _]} = Inbox.list_items(ctx.scope)
  end

  test "dropping a bill deletes it from the list", %{conn: conn} = ctx do
    item = read_bill!(ctx.scope, @electric)
    {:ok, lv, _} = live(conn, ~p"/inbox/#{item}")

    {:ok, _, html} = lv |> element("button", "drop it") |> render_click() |> follow_redirect(conn)
    assert html =~ "Dropped."
    assert html =~ "Nothing to check."
    assert {:ok, []} = Ledger.list_expenses(ctx.scope, ctx.group.id)
  end

  test "an unreadable bill opens a blank form beside the original", %{conn: conn} = ctx do
    {:ok, item} =
      Inbox.upload(ctx.scope, %{content_type: "application/pdf", data: "%PDF-1.4 smudge"})

    Req.Test.stub(
      Tab.Reader,
      &(&1 |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "off"}))
    )

    :ok = perform_job(ReadWorker, %{item_id: item.id, user_id: ctx.user.id})

    {:ok, _, html} = live(conn, ~p"/inbox")
    assert html =~ "Fill it in by hand"

    {:ok, _, html} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?item=#{item.id}")
    assert html =~ "From the bill you sent"
    assert html =~ ~s(id="expense_amount")
  end

  test "nobody else sees your bills or their originals", %{conn: conn} = ctx do
    item = read_bill!(ctx.scope, @electric)
    [doc] = Repo.all(Tab.Inbox.Document)
    sam = as(conn, ctx.sam)

    assert_raise TabWeb.GroupData.NotFound, fn -> live(sam, ~p"/inbox/#{item}") end

    assert_raise TabWeb.GroupData.NotFound, fn ->
      live(sam, ~p"/groups/#{ctx.group}/expenses/new?item=#{item.id}")
    end

    assert response(get(sam, ~p"/documents/#{doc.id}"), 404)
    {:ok, _, html} = live(sam, ~p"/inbox")
    refute html =~ "PG&amp;E"
  end

  describe "forwarding" do
    test "shows your address, steps, and Gmail's code", %{conn: conn} = ctx do
      {:ok, lv, html} = live(conn, ~p"/inbox/forwarding")
      {:ok, address} = Inbox.address(ctx.scope, ctx.group.id)
      assert html =~ Inbox.address_text(address)
      assert html =~ "For Elm Street"
      assert html =~ "In Gmail"

      Repo.insert!(%Message{
        provider_id: "e1",
        user_id: ctx.user.id,
        status: "stored",
        kind: "gmail_check",
        detail: "123456789",
        from_address: "forwarding-noreply@google.com",
        subject: "Gmail Forwarding Confirmation",
        received_at: DateTime.utc_now(:second)
      })

      html = lv |> element("button", "Make a new one") |> render_click()
      refute html =~ Inbox.address_text(address)
      assert html =~ "Gmail&#39;s code: 123456789"
    end

    test "says so when this server can't receive mail", %{conn: conn} do
      Application.put_env(:tab, :inbound_domain, nil)
      on_exit(fn -> Application.put_env(:tab, :inbound_domain, "bills.test") end)

      {:ok, _, html} = live(conn, ~p"/inbox/forwarding")
      assert html =~ "can&#39;t receive email"
    end
  end

  test "digest days are set on the You page", %{conn: conn} = ctx do
    {:ok, lv, html} = live(conn, ~p"/profile")
    assert html =~ "On the 10th and the 25th"

    lv |> form("#digest_form", digest: "each") |> render_submit()
    assert Accounts.get_profile(ctx.scope).digest_days == []
  end

  test "the groups page says when bills are ready", %{conn: conn} = ctx do
    read_bill!(ctx.scope, @electric)
    {:ok, _, html} = live(conn, ~p"/groups")
    assert html =~ "A bill you sent is waiting for you to check"
  end
end
