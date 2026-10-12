defmodule TabWeb.JourneyTest do
  @moduledoc """
  Phase 2 tests 2 and 3: whole journeys through the pages, the way people use
  them. Sign-up goes through the real emailed link.
  """
  use TabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  # Signs up through the login page and the emailed link; returns a signed-in conn.
  defp sign_up(email, name) do
    conn = build_conn()
    {:ok, lv, _} = live(conn, ~p"/users/log-in")
    lv |> form("#login_form_magic", user: %{email: email}) |> render_submit()

    url =
      receive do
        {:email, %{to: [{_, ^email}], text_body: body}} ->
          [url] = Regex.run(~r{http://\S+/users/log-in/\S+}, body)
          url
      after
        1_000 -> flunk("no sign-in email for #{email}")
      end

    path = URI.parse(url).path
    {:ok, lv, html} = live(conn, path)
    assert html =~ "Welcome to Tab"

    form = form(lv, "#confirmation_form")
    render_submit(form, %{"user" => %{"remember_me" => "true"}})
    conn = follow_trigger_action(form, conn)
    assert redirected_to(conn) == ~p"/welcome"

    conn = conn |> recycle()
    {:ok, lv, _} = live(conn, ~p"/welcome")

    {:ok, _, _} =
      lv
      |> form("#welcome_form", profile: %{display_name: name})
      |> render_submit()
      |> follow_redirect(conn)

    conn
  end

  defp add_expense(conn, group_id, expense, extra \\ %{}) do
    {:ok, lv, _} = live(conn, ~p"/groups/#{group_id}/expenses/new")

    # Choosing the split type first makes its value fields appear.
    lv |> form("#expense_form", expense: Map.take(expense, [:split_type])) |> render_change()

    {:ok, _, html} =
      lv
      |> form("#expense_form", Map.merge(%{expense: expense}, extra))
      |> render_submit()
      |> follow_redirect(conn)

    html
  end

  defp group_html(conn, group_id) do
    {:ok, _, html} = live(conn, ~p"/groups/#{group_id}")
    html
  end

  defp id_of(email), do: Tab.Accounts.get_user_by_email(email).id

  test "two housemates: sign up, invite, every split, a partial payment, export" do
    priya = sign_up("priya@example.com", "Priya")

    # Create the group.
    {:ok, lv, _} = live(priya, ~p"/groups")

    {:ok, _, html} =
      lv
      |> form("#new_group", group: %{name: "Elm Street"})
      |> render_submit()
      |> follow_redirect(priya)

    assert html =~ "Elm Street"
    [_, group_id] = Regex.run(~r"/groups/([0-9a-f-]{36})/settle", html)

    # Invite Sam, who signs up from the link.
    {:ok, lv, _} = live(priya, ~p"/groups/#{group_id}/members")
    html = lv |> element("button", "Make an invite link") |> render_click()
    [_, token] = Regex.run(~r{/join/([A-Za-z0-9_-]+)}, html)

    sam = sign_up("sam@example.com", "Sam")
    {:ok, lv, _} = live(sam, ~p"/join/#{token}")
    {:ok, _, html} = lv |> element("#join") |> render_click() |> follow_redirect(sam)
    assert html =~ "Elm Street"

    p = "user:" <> id_of("priya@example.com")
    s = "user:" <> id_of("sam@example.com")

    # Every split type, all paid by Priya.
    add_expense(priya, group_id, %{description: "Groceries", amount: "40", split_type: "equal"})

    add_expense(priya, group_id, %{description: "Dinner", amount: "50", split_type: "exact"}, %{
      value: %{p => "20", s => "30"}
    })

    add_expense(
      priya,
      group_id,
      %{description: "Electric", amount: "100", split_type: "percentage"},
      %{
        value: %{p => "60", s => "40"}
      }
    )

    add_expense(priya, group_id, %{description: "Wine", amount: "30", split_type: "shares"}, %{
      value: %{p => "1", s => "2"}
    })

    html =
      add_expense(
        priya,
        group_id,
        %{description: "Rent", amount: "1000", split_type: "tiered", rest_type: "equal"},
        %{fixed: %{p => "200"}}
      )

    assert html =~ "Fixed amounts first"

    # Sam owes 20 + 30 + 40 + 20 + 400 = $510.00.
    assert group_html(sam, group_id) =~ "$510.00"

    # Sam pays part of it; it counts once Priya confirms.
    {:ok, lv, _} = live(sam, ~p"/groups/#{group_id}/settle")

    lv
    |> form("#payment_form",
      payment: %{from: s, to: p, amount: "200", method: "zelle", reference: "October"}
    )
    |> render_submit()

    assert group_html(sam, group_id) =~ "$510.00"

    {:ok, lv, html} = live(priya, ~p"/groups/#{group_id}")
    assert html =~ "Did this arrive?"
    lv |> element("#pending button", "Yes, got it") |> render_click()

    html = group_html(sam, group_id)
    assert html =~ "$310.00"
    refute html =~ "$510.00"

    # Export.
    csv = sam |> get(~p"/export.csv") |> response(200)
    assert csv =~ "Elm Street,expense,"
    assert csv =~ "Rent"
    assert csv =~ ",400.00,"
    assert csv =~ "Elm Street,payment,"
    assert csv =~ "zelle,October,confirmed"
  end

  test "Marcus on his own: counterparties only, no invite ever sent" do
    marcus = sign_up("marcus@example.com", "Marcus")
    {:ok, lv, _} = live(marcus, ~p"/groups")

    {:ok, _, html} =
      lv
      |> form("#new_group", group: %{name: "My place"})
      |> render_submit()
      |> follow_redirect(marcus)

    [_, group_id] = Regex.run(~r"/groups/([0-9a-f-]{36})/settle", html)

    {:ok, lv, _} = live(marcus, ~p"/groups/#{group_id}/members")
    lv |> form("#counterparty_form", name: "The Okafors") |> render_submit()

    [cp] =
      Tab.Repo.query!("SELECT id::text FROM counterparties WHERE name = 'The Okafors'").rows
      |> List.flatten()

    m = "user:" <> id_of("marcus@example.com")
    o = "counterparty:" <> cp

    add_expense(
      marcus,
      group_id,
      %{description: "Water bill", amount: "90", split_type: "equal"},
      %{
        in: %{m => "true", o => "true"}
      }
    )

    assert group_html(marcus, group_id) =~ ~r/The Okafors.*owes.*you.*\$45\.00/s

    {:ok, lv, _} = live(marcus, ~p"/groups/#{group_id}/settle")

    html =
      lv
      |> form("#payment_form", payment: %{from: o, to: m, amount: "45", method: "cash"})
      |> render_submit()

    assert html =~ "Recorded."
    refute html =~ "Waiting to be confirmed"
    assert group_html(marcus, group_id) =~ "Everyone&#39;s even."
    assert_no_email_sent()
  end
end
