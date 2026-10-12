# Demo data for local development: `mix run priv/repo/seeds.exs` (part of
# `mix ecto.setup`). Safe to re-run: it does nothing if the demo users exist.
#
# Sign in as priya@example.com or sam@example.com; links land in /dev/mailbox.

alias Tab.{Accounts, Groups, Ledger, Repo}
alias Tab.Accounts.{Scope, User}

if Repo.get_by(User, email: "priya@example.com") do
  IO.puts("Demo data already there.")
else
  person = fn email, name, methods ->
    {:ok, user} = Accounts.register_user(%{email: email})
    user = user |> User.confirm_changeset() |> Repo.update!()
    scope = Scope.for_user(user)
    {:ok, _} = Accounts.update_profile(scope, %{display_name: name, payment_methods: methods})
    {user, scope}
  end

  {priya, ps} =
    person.("priya@example.com", "Priya", [%{"kind" => "venmo", "handle" => "@priya-k"}])

  {sam, ss} =
    person.("sam@example.com", "Sam", [%{"kind" => "zelle", "handle" => "sam@example.com"}])

  {jo, js} = person.("jo@example.com", "Jo", [])

  {:ok, house} = Groups.create_group(ps, %{name: "Elm Street house"})

  for s <- [ss, js] do
    {:ok, {token, _}} = Groups.create_invite(ps, house.id)
    {:ok, _} = Groups.accept_invite(s, token)
  end

  {:ok, landlord} = Groups.create_counterparty(ps, house.id, %{name: "Landlord"})
  {:ok, categories} = Groups.list_categories(ps, house.id)
  cat = fn name -> Enum.find(categories, &(&1.name == name)).id end
  everyone = Enum.map([priya, sam, jo], &%{"user_id" => &1.id})

  add = fn scope, attrs ->
    {:ok, e} = Ledger.create_expense(scope, house.id, attrs)
    e
  end

  add.(ps, %{
    description: "October rent",
    amount_cents: 360_000,
    date: ~D[2026-10-01],
    paid_by: priya.id,
    category_id: cat.("Rent"),
    split: %{
      "type" => "tiered",
      "entries" => [%{"user_id" => priya.id, "value" => 30_000}],
      "rest" => %{"type" => "equal", "entries" => everyone}
    }
  })

  add.(ss, %{
    description: "Electric",
    amount_cents: 14_237,
    date: ~D[2026-10-04],
    paid_by: sam.id,
    category_id: cat.("Utilities"),
    split: %{"type" => "equal", "entries" => everyone}
  })

  add.(js, %{
    description: "Groceries, big shop",
    amount_cents: 18_650,
    date: ~D[2026-10-06],
    paid_by: jo.id,
    category_id: cat.("Groceries"),
    split: %{"type" => "shares", "entries" => Enum.map(everyone, &Map.put(&1, "value", 1))}
  })

  add.(ps, %{
    description: "Hallway paint (landlord pays half)",
    amount_cents: 8_400,
    date: ~D[2026-10-08],
    paid_by: priya.id,
    split: %{
      "type" => "percentage",
      "entries" => [
        %{"counterparty_id" => landlord.id, "value" => 50},
        %{"user_id" => priya.id, "value" => 50}
      ]
    }
  })

  add.(ps, %{
    description: "Therapy copay",
    amount_cents: 4_000,
    date: ~D[2026-10-09],
    paid_by: priya.id,
    visibility: "private",
    split: %{"type" => "equal", "entries" => [%{"user_id" => priya.id}]}
  })

  {:ok, _} =
    Ledger.record_payment(ss, house.id, %{
      from_user_id: sam.id,
      to_user_id: priya.id,
      amount_cents: 50_000,
      date: ~D[2026-10-10],
      method: "zelle",
      reference: "rent, part 1"
    })

  {:ok, _} = Groups.create_group(ps, %{name: "Ski trip"})
  IO.puts("Demo data added. Sign in as priya@example.com.")
end

# Phase 3 demo: recurring bills and a temporary split. Added once, also to demo
# data made before phase 3.
priya = Repo.get_by!(User, email: "priya@example.com")
ps = Scope.for_user(priya)
{:ok, groups} = Groups.list_groups(ps)
house = Enum.find(groups, &(&1.name == "Elm Street house"))
{:ok, bills} = Tab.Bills.list_templates(ps, house.id)

if bills == [] do
  {:ok, members} = Groups.list_members(ps, house.id)
  {:ok, categories} = Groups.list_categories(ps, house.id)
  cat = fn name -> Enum.find(categories, &(&1.name == name)).id end
  id = fn name -> Enum.find(members, &(&1.profile.display_name == name)).user_id end

  {:ok, _} =
    Tab.Bills.create_template(ps, house.id, %{
      name: "Rent",
      category_id: cat.("Rent"),
      stability: "fixed",
      autopay_day: 1,
      default_payer: priya.id,
      default_split: %{
        "type" => "exact",
        "entries" => [
          %{"user_id" => priya.id, "value" => 140_000},
          %{"user_id" => id.("Sam"), "value" => 110_000},
          %{"user_id" => id.("Jo"), "value" => 110_000}
        ]
      }
    })

  {:ok, _} =
    Tab.Bills.create_template(ps, house.id, %{
      name: "Internet",
      category_id: cat.("Internet"),
      autopay_day: 15,
      default_payer: id.("Sam")
    })

  {:ok, _} =
    Tab.Bills.create_override(ps, house.id, %{
      category_id: cat.("Utilities"),
      effective_from: ~D[2026-11-01],
      effective_until: ~D[2026-11-30],
      note: "Jo away",
      split: %{
        "type" => "equal",
        "entries" => [%{"user_id" => priya.id}, %{"user_id" => id.("Sam")}]
      }
    })

  IO.puts("Demo bills added.")
end

# Phase 4 demo: two bills to check, one read and one to type in by hand. The
# reader isn't called: the reading is filled in here.
{:ok, waiting} = Tab.Inbox.list_items(ps)

if waiting == [] do
  {:ok, read} =
    Tab.Inbox.upload(ps, %{
      content_type: "application/pdf",
      filename: "pge-october.pdf",
      data: "%PDF-1.4 demo PG&E bill"
    })

  {:ok, smudged} =
    Tab.Inbox.upload(ps, %{
      content_type: "application/pdf",
      filename: "receipt.pdf",
      data: "%PDF-1.4 demo receipt"
    })

  today = Date.utc_today()

  {:ok, _} =
    Tab.Inbox.save_reading(
      ps,
      read,
      Tab.Inbox.Proposal.validate(%{
        "doc_type" => "utility",
        "merchant" => "PG&E",
        "total_cents" => 8_420,
        "date" => Date.to_iso8601(Date.add(today, -2)),
        "due_on" => Date.to_iso8601(Date.add(today, 3)),
        "period_start" => Date.to_iso8601(Date.add(today, -33)),
        "period_end" => Date.to_iso8601(Date.add(today, -3))
      }),
      "billing@pge.com"
    )

  {:ok, _} = Tab.Inbox.mark(ps, smudged, "unreadable", "couldn't read this one")
  IO.puts("Demo bills to check added.")
end
