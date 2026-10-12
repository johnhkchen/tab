defmodule Tab.RemindersTest do
  @moduledoc "Phase 3 test 5: drafts for Venmo, a text, and an email from the same balance."
  use ExUnit.Case, async: true

  alias Tab.Reminders

  @facts %{
    to: "Sam",
    from: "Priya",
    group: "Elm Street",
    amount_cents: 31_000,
    items: [
      %{description: "Electric", date: ~D[2026-10-05]},
      %{description: "Internet", date: ~D[2026-10-08]},
      %{description: "Water", date: ~D[2026-10-09]},
      %{description: "Trash", date: ~D[2026-10-11]}
    ],
    methods: [
      %{"kind" => "venmo", "handle" => "@priya"},
      %{"kind" => "zelle", "handle" => "priya@example.com"}
    ],
    link: "https://tab.example/s/abc"
  }

  test "every draft says how much, from the same facts" do
    drafts = Reminders.drafts(@facts)

    for text <- [drafts.venmo, drafts.text, drafts.email.subject, drafts.email.body] do
      assert text =~ "$310.00"
    end
  end

  test "the Venmo note is one short line" do
    note = Reminders.drafts(@facts).venmo
    refute note =~ "\n"
    assert String.length(note) <= 280
    assert note == "Elm Street: Electric, Internet and 2 more $310.00"
  end

  test "the text names the bills, how to pay, and the link" do
    text = Reminders.drafts(@facts).text

    assert text ==
             "Hi Sam, your share of Elm Street bills comes to $310.00 " <>
               "(Electric, Internet, Water and 1 more). " <>
               "You can pay me by Venmo @priya or Zelle priya@example.com. " <>
               "The details: https://tab.example/s/abc Thanks!"
  end

  test "the email lists every open bill and signs off" do
    %{subject: subject, body: body} = Reminders.drafts(@facts).email
    assert subject == "Elm Street: $310.00 to settle up"
    assert body =~ "- Trash (Oct 11)"
    assert body =~ "line by line: https://tab.example/s/abc"
    assert String.ends_with?(body, "Thanks,\nPriya")
  end

  test "no bills, no methods, no link still reads well" do
    drafts = Reminders.drafts(%{@facts | items: [], methods: [], link: nil})
    assert drafts.venmo == "Elm Street: bills $310.00"
    assert drafts.text == "Hi Sam, your share of Elm Street bills comes to $310.00. Thanks!"
  end
end
