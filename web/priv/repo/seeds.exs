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
