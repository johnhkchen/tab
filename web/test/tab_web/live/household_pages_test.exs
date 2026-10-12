defmodule TabWeb.HouseholdPagesTest do
  @moduledoc """
  Phase 3 pages: bills logged in a tap, the fixed-amount check, autopay dates,
  temporary splits and the combine flow, suggested and prorated splits in the
  add-expense form, how long money waits, reminder drafts, and statement links
  opened without signing in.
  """
  use TabWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tab.AccountsFixtures

  alias Tab.{Accounts, Bills, Groups, Ledger}
  alias Tab.Bills.{Dates, Suggest}

  setup :register_and_log_in_user

  setup %{scope: scope, user: user} do
    Accounts.update_profile(scope, %{
      display_name: "Priya",
      payment_methods: [%{"kind" => "venmo", "handle" => "@priya"}]
    })

    {:ok, group} = Groups.create_group(scope, %{name: "Elm Street"})
    sam = user_fixture()
    sam_scope = Accounts.Scope.for_user(sam)
    Accounts.update_profile(sam_scope, %{display_name: "Sam"})
    {:ok, {token, _}} = Groups.create_invite(scope, group.id)
    {:ok, _} = Groups.accept_invite(sam_scope, token)
    {:ok, cats} = Groups.list_categories(scope, group.id)

    %{
      group: group,
      sam: sam,
      sam_scope: sam_scope,
      p: "user:" <> user.id,
      s: "user:" <> sam.id,
      cat: Map.new(cats, &{&1.name, &1.id})
    }
  end

  defp as(conn, user), do: conn |> recycle() |> log_in_user(user)

  defp template!(ctx, attrs) do
    {:ok, t} =
      Bills.create_template(ctx.scope, ctx.group.id, Map.merge(%{name: "Internet"}, attrs))

    t
  end

  defp expenses(ctx) do
    {:ok, list} = Ledger.list_expenses(ctx.scope, ctx.group.id)
    list
  end

  describe "bills" do
    test "add one, then log it in a tap as a normal expense", %{conn: conn} = ctx do
      {:ok, lv, html} = live(conn, ~p"/groups/#{ctx.group}/bills")
      assert html =~ "No bills yet"

      lv
      |> form("#bill_form",
        bill: %{name: "Internet", category_id: ctx.cat["Internet"], cadence: "monthly"},
        split_type: "equal"
      )
      |> render_submit()

      html = render(lv)
      assert html =~ "Every month"
      [t] = elem(Bills.list_templates(ctx.scope, ctx.group.id), 1)
      assert t.default_split["type"] == "equal"

      {:ok, form, html} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?template=#{t.id}")
      assert html =~ ~s(value="Internet")

      {:ok, _, html} =
        form
        |> form("#expense_form", expense: %{amount: "60"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Internet"
      assert [%{template_id: tid, amount_cents: 6_000}] = expenses(ctx)
      assert tid == t.id

      # Next time it starts at the last amount.
      {:ok, _, html} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?template=#{t.id}")
      assert html =~ ~s(value="60.00")
    end

    test "a fixed bill at a new amount needs a tick; a variable one doesn't",
         %{conn: conn} = ctx do
      rent = template!(ctx, %{name: "Rent", stability: "fixed"})
      power = template!(ctx, %{name: "Power", stability: "variable"})

      for {t, amount} <- [{rent, "1000"}, {power, "80"}] do
        {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?template=#{t.id}")
        lv |> form("#expense_form", expense: %{amount: amount}) |> render_submit()
      end

      {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?template=#{rent.id}")
      html = lv |> form("#expense_form", expense: %{amount: "1050"}) |> render_change()
      assert html =~ "Rent is usually"

      html = lv |> form("#expense_form", expense: %{amount: "1050"}) |> render_submit()
      assert html =~ "tick this to save a different amount"
      assert length(expenses(ctx)) == 2

      {:ok, _, _} =
        lv
        |> form("#expense_form", expense: %{amount: "1050", amount_changed: "true"})
        |> render_submit()
        |> follow_redirect(conn)

      assert length(expenses(ctx)) == 3

      {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?template=#{power.id}")
      refute lv |> form("#expense_form", expense: %{amount: "95"}) |> render_change() =~ "usually"
    end

    test "an autopay day sets the date, clamped to the month, and it stays editable",
         %{conn: conn} = ctx do
      t = template!(ctx, %{autopay_day: 31})
      {:ok, lv, html} = live(conn, ~p"/groups/#{ctx.group}/expenses/new?template=#{t.id}")

      expected = Dates.autopay_date(31, Date.utc_today())
      assert html =~ ~s(id="expense_date" value="#{expected}")
      {from, to} = Dates.period("monthly", nil, expected)
      assert html =~ ~s(value="#{from}")
      assert html =~ ~s(value="#{to}")

      {:ok, _, _} =
        lv
        |> form("#expense_form", expense: %{amount: "60", date: "2026-10-02"})
        |> render_submit()
        |> follow_redirect(conn)

      assert [%{date: ~D[2026-10-02]}] = expenses(ctx)
    end
  end

  describe "temporary splits" do
    test "someone's away proposes a split without them; members only read", %{conn: conn} = ctx do
      {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/temporary")

      html =
        lv
        |> form("#override_form", o: %{away: ctx.sam.id, category_id: ctx.cat["Utilities"]})
        |> render_change()

      assert html =~ ~s(value="Sam away")
      refute html =~ ~s(id="in-#{ctx.s}" checked)

      lv
      |> form("#override_form",
        o: %{effective_from: "2026-11-01", effective_until: "2026-11-30"}
      )
      |> render_submit()

      assert render(lv) =~ "Nov 1, 2026 to Nov 30, 2026"

      {:ok, _, html} = live(as(conn, ctx.sam), ~p"/groups/#{ctx.group}/temporary")
      assert html =~ "Sam away"
      assert html =~ "Only admins set these"
      refute html =~ "override_form"
    end

    test "an overlap shows the clash and saves side by side once confirmed",
         %{conn: conn} = ctx do
      {:ok, _} =
        Bills.create_override(ctx.scope, ctx.group.id, %{
          category_id: ctx.cat["Utilities"],
          effective_from: ~D[2026-11-01],
          effective_until: ~D[2026-11-30],
          split: Suggest.equal([{:user, ctx.user.id}]),
          note: "Sam away"
        })

      {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/temporary")

      html =
        lv
        |> form("#override_form",
          o: %{
            note: "Guest",
            category_id: ctx.cat["Utilities"],
            effective_from: "2026-11-20",
            effective_until: "2026-12-05"
          },
          split_type: "equal"
        )
        |> render_submit()

      assert html =~ "This overlaps"
      assert html =~ "Guest and Sam away"

      html = lv |> element("button", "Save it this way") |> render_click()
      assert html =~ "Saved side by side"
      assert {:ok, [_, _, _]} = Bills.list_overrides(ctx.scope, ctx.group.id)
    end
  end

  describe "the add-expense form suggests a split" do
    setup ctx do
      today = Date.utc_today()

      {:ok, _} =
        Bills.create_override(ctx.scope, ctx.group.id, %{
          category_id: ctx.cat["Utilities"],
          effective_from: Date.add(today, -5),
          effective_until: Date.add(today, 4),
          split: Suggest.equal([{:user, ctx.user.id}]),
          note: "Sam away"
        })

      %{today: today}
    end

    test "inside the window for that category, and not for rent", %{conn: conn} = ctx do
      {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/expenses/new")

      html =
        lv
        |> form("#expense_form", expense: %{category_id: ctx.cat["Utilities"], amount: "90"})
        |> render_change()

      assert html =~ "Sam away covers this date"
      refute html =~ ~s(id="in-#{ctx.s}" checked)

      html =
        lv
        |> form("#expense_form", expense: %{category_id: ctx.cat["Rent"]})
        |> render_change()

      refute html =~ "Sam away"
      assert html =~ ~s(id="in-#{ctx.s}" checked)
    end

    test "a bill covering a period blends by day", %{conn: conn} = ctx do
      {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/expenses/new")

      html =
        lv
        |> form("#expense_form",
          expense: %{
            category_id: ctx.cat["Utilities"],
            amount: "200",
            period_start: Date.to_iso8601(Date.add(ctx.today, -14)),
            period_end: Date.to_iso8601(Date.add(ctx.today, 5))
          }
        )
        |> render_change()

      # Sam is away 10 of the bill's 20 days: a quarter of it is theirs.
      assert html =~ "Sam away for 10 of its 20 days"
      assert html =~ "$50.00"
      assert html =~ "$150.00"
    end

    test "editing the split yourself stops the suggestions", %{conn: conn} = ctx do
      {:ok, lv, _} = live(conn, ~p"/groups/#{ctx.group}/expenses/new")
      lv |> form("#expense_form", expense: %{split_type: "shares"}) |> render_change()

      html =
        lv
        |> form("#expense_form", expense: %{category_id: ctx.cat["Utilities"]})
        |> render_change()

      refute html =~ "Sam away"
    end
  end

  describe "chasing money" do
    setup ctx do
      {:ok, e} =
        Ledger.create_expense(ctx.scope, ctx.group.id, %{
          description: "Electric",
          amount_cents: 9_000,
          date: Date.add(Date.utc_today(), -3),
          paid_by: ctx.user.id,
          split: Suggest.equal([{:user, ctx.user.id}, {:user, ctx.sam.id}])
        })

      %{expense: e}
    end

    test "the group page links to Ask for it and shows how long money waits",
         %{conn: conn} = ctx do
      {:ok, _, html} = live(conn, ~p"/groups/#{ctx.group}")
      assert html =~ "Ask for it"
      assert html =~ "How long money waits"
      assert html =~ "3 days"

      {:ok, _, html} = live(conn, ~p"/groups/#{ctx.group}/expenses/#{ctx.expense}")
      assert html =~ "waiting 3 days so far"
    end

    test "drafts for Venmo, a text, and an email, then a statement link", %{conn: conn} = ctx do
      {:ok, lv, html} = live(conn, ~p"/groups/#{ctx.group}/remind/#{ctx.s}")
      assert html =~ "Sam owes you"
      assert html =~ "Elm Street: Electric $45.00"
      assert html =~ "You can pay me by Venmo @priya"
      assert html =~ "Subject: Elm Street: $45.00 to settle up"

      html = lv |> form("#link_form") |> render_submit()
      [_, path] = Regex.run(~r{http://[^/"]+(/s/[A-Za-z0-9_-]+)}, html)
      assert html =~ "The details: http"

      # Opened by anyone with the link, no sign-in.
      page = build_conn() |> get(path)
      assert html_response(page, 200) =~ "Electric"
      assert get_resp_header(page, "cache-control") == ["no-store"]
      assert get_resp_header(page, "referrer-policy") == ["no-referrer"]

      html = lv |> element("#links button", "Turn off") |> render_click()
      assert html =~ "Turned off"
      assert html_response(build_conn() |> get(path), 404) =~ "t work anymore"
      assert html_response(build_conn() |> get(~p"/s/made-up"), 404) =~ "t work anymore"
    end
  end

  test "outsiders get a plain 404, and you can't ask yourself", %{conn: conn} = ctx do
    for path <- [
          ~p"/groups/#{ctx.group}/bills",
          ~p"/groups/#{ctx.group}/temporary",
          ~p"/groups/#{ctx.group}/remind/#{ctx.p}"
        ] do
      assert_raise TabWeb.GroupData.NotFound, fn -> live(as(conn, user_fixture()), path) end
    end

    assert_raise TabWeb.GroupData.NotFound, fn ->
      live(conn, ~p"/groups/#{ctx.group}/remind/#{ctx.p}")
    end

    assert_raise TabWeb.GroupData.NotFound, fn ->
      live(conn, ~p"/groups/#{ctx.group}/remind/user:#{Ecto.UUID.generate()}")
    end
  end
end
