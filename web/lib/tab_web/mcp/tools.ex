defmodule TabWeb.MCP.Tools do
  @moduledoc """
  The tools Claude can call (docs/specification.md, "Tools"). Each is a thin
  layer over the same contexts the web pages use, called with a scope marked
  `via: "claude"`, so the database applies the person's own policies and
  stamps what they add as added from Claude.

  Groups and people are named by name or id; amounts go in and out as decimal
  strings. Results are plain maps; `TabWeb.MCP` sends them as JSON.
  """
  alias Tab.{Groups, Inbox, Ledger}
  alias TabWeb.Format

  @read %{readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false}
  @write %{
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: false
  }

  @group %{
    type: "string",
    description: "The group's name or id. Optional when the person has just one group."
  }
  @amount %{type: "string", description: ~s(An amount like "43.10". No currency sign needed.)}
  @date %{type: "string", format: "date", description: "YYYY-MM-DD. Defaults to today."}
  @party %{
    type: "string",
    description:
      ~s(A member's name, "me", or an outside party's name (a landlord, a utility\), or an id.)
  }

  @split_entries %{
    type: "array",
    items: %{
      type: "object",
      properties: %{
        who: @party,
        value: %{
          type: "string",
          description:
            "exact and tiered: an amount; percentage: a percent; shares: a whole number. Leave out for equal."
        }
      },
      required: ["who"]
    }
  }

  @tools [
    %{
      name: "list_groups",
      title: "List groups",
      description:
        "The person's groups in Tab, each with its members, outside parties (counterparties), and categories. Call this first to learn the names to use.",
      inputSchema: %{type: "object", properties: %{}},
      annotations: @read,
      scope: "tab:read"
    },
    %{
      name: "get_balances",
      title: "Get balances",
      description:
        "Who owes whom in a group, overall or by category. With no group, the person's net in each of their groups (positive means they're owed).",
      inputSchema: %{
        type: "object",
        properties: %{
          group: @group,
          by_category: %{type: "boolean", description: "Split the balances by category."}
        }
      },
      annotations: @read,
      scope: "tab:read"
    },
    %{
      name: "list_recent_expenses",
      title: "List recent expenses",
      description:
        "A group's latest expenses, newest first, with who paid and each person's share. Private expenses show only the person's own.",
      inputSchema: %{
        type: "object",
        properties: %{
          group: @group,
          limit: %{type: "integer", minimum: 1, maximum: 100, description: "Default 20."},
          category: %{type: "string", description: "Only this category."},
          person: %{type: "string", description: "Only expenses this person paid or shares in."}
        }
      },
      annotations: @read,
      scope: "tab:read"
    },
    %{
      name: "suggest_settle_up",
      title: "Suggest settling up",
      description:
        "The fewest payments that would even everyone out in a group. Records nothing; use record_payment once money has moved.",
      inputSchema: %{type: "object", properties: %{group: @group}},
      annotations: @read,
      scope: "tab:read"
    },
    %{
      name: "list_bills_to_check",
      title: "List bills to check",
      description:
        "Bills Tab read from the person's uploads and forwarded email that still need checking, with a link to check each one on the web. Confirming happens on the web, where the document is.",
      inputSchema: %{type: "object", properties: %{}},
      annotations: @read,
      scope: "tab:read"
    },
    %{
      name: "add_expense",
      title: "Add an expense",
      description:
        "Adds an expense to a group and saves it right away. The split defaults to equal among all members. Split types: equal, exact (amounts that add up to the total), percentage (adds up to 100), shares (whole-number weights), tiered (fixed amounts off the top, then a simple split of the rest). Everyone in the split gets the usual email.",
      inputSchema: %{
        type: "object",
        properties: %{
          group: @group,
          description: %{type: "string", description: ~s(What it was for, like "Groceries".)},
          amount: @amount,
          date: @date,
          paid_by: Map.put(@party, :description, ~s(The member who paid. Defaults to "me".)),
          category: %{type: "string", description: "A category name from list_groups."},
          private: %{
            type: "boolean",
            description: "Only the person sees it; it never touches anyone's balance."
          },
          split: %{
            type: "object",
            properties: %{
              type: %{type: "string", enum: ~w(equal exact percentage shares tiered)},
              with: @split_entries,
              rest: %{
                type: "object",
                description: "tiered only: how to split what's left after the fixed amounts.",
                properties: %{
                  type: %{type: "string", enum: ~w(equal exact percentage shares)},
                  with: @split_entries
                },
                required: ["type", "with"]
              }
            },
            required: ["type", "with"]
          }
        },
        required: ["description", "amount"]
      },
      annotations: @write,
      scope: "tab:write"
    },
    %{
      name: "record_payment",
      title: "Record a payment",
      description:
        "Records money that moved between two people in a group. A payment to another member waits for them to confirm it in Tab; a payment with an outside party counts at once.",
      inputSchema: %{
        type: "object",
        properties: %{
          group: @group,
          from: Map.put(@party, :description, ~s(Who paid. Defaults to "me".)),
          to: Map.put(@party, :description, "Who got the money."),
          amount: @amount,
          method: %{type: "string", enum: ~w(venmo zelle cashapp paypal cash check other)},
          date: @date,
          reference: %{type: "string", description: "A Venmo note, check number, and so on."},
          category: %{type: "string", description: "Settles this category only."}
        },
        required: ["to", "amount", "method"]
      },
      annotations: @write,
      scope: "tab:write"
    }
  ]

  @doc "The tools as `tools/list` returns them."
  def list, do: Enum.map(@tools, &Map.delete(&1, :scope))

  @doc "The scope a tool needs, or nil for an unknown tool."
  def scope_for(name), do: Enum.find_value(@tools, &(&1.name == name && &1.scope))

  @doc "Runs a tool. `{:ok, result}` or `{:error, message}` for Claude to read."
  def call(name, args, scope) when is_map(args) do
    run(name, args, scope)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error,
       "Tab couldn't do that: " <> (Tab.DBError.reason(e) |> describe() || "database error")}
  end

  def call(name, _args, scope), do: call(name, %{}, scope)

  ## Reads

  defp run("list_groups", _args, scope) do
    {:ok, groups} = Groups.list_groups(scope)

    {:ok,
     %{
       groups:
         for g <- groups do
           %{members: members, counterparties: cps, categories: cats} = people(scope, g.id)

           %{
             id: g.id,
             name: g.name,
             archived: not is_nil(g.deleted_at),
             members:
               Enum.map(members, &%{id: &1.id, name: &1.name, you: &1.id == scope.user.id}),
             counterparties: Enum.map(cps, &%{id: &1.id, name: &1.name}),
             categories: Enum.map(cats, &%{id: &1.id, name: &1.name})
           }
         end
     }}
  end

  defp run("get_balances", %{"group" => g} = args, scope) when is_binary(g) and g != "" do
    with {:ok, group} <- group(scope, g) do
      names = names(scope, group.id)

      if args["by_category"] do
        {:ok, rows} = Ledger.category_balances(scope, group.id)
        cats = Map.new(people(scope, group.id).categories, &{&1.id, &1.name})

        {:ok,
         %{
           group: group.name,
           by_category:
             for r <- rows do
               r |> balance_row(names) |> Map.put(:category, Map.get(cats, r.category_id, "None"))
             end
         }}
      else
        {:ok, rows} = Ledger.balances(scope, group.id)
        {:ok, %{group: group.name, balances: Enum.map(rows, &balance_row(&1, names))}}
      end
    end
  end

  defp run("get_balances", _args, scope) do
    {:ok, groups} = Groups.list_groups(scope)
    {:ok, nets} = Ledger.my_nets(scope)

    {:ok,
     %{
       groups:
         for g <- groups do
           n = Map.get(nets, g.id, 0)

           %{
             group: g.name,
             net: decimal(n),
             in_words:
               cond do
                 n > 0 -> "you're owed #{Format.money(n)}"
                 n < 0 -> "you owe #{Format.money(-n)}"
                 true -> "even"
               end
           }
         end
     }}
  end

  defp run("list_recent_expenses", args, scope) do
    with {:ok, group} <- group(scope, args["group"]),
         {:ok, expenses} <- Ledger.list_expenses(scope, group.id),
         %{categories: cats} = people = people(scope, group.id),
         {:ok, category} <- optional_category(cats, args["category"]),
         {:ok, person} <- optional_party(people, scope, args["person"]) do
      names = names(scope, group.id)
      cat_names = Map.new(cats, &{&1.id, &1.name})
      limit = args["limit"] |> to_int(20) |> max(1) |> min(100)

      expenses =
        expenses
        |> Enum.filter(&(is_nil(category) or &1.category_id == category.id))
        |> Enum.filter(&(is_nil(person) or involves?(&1, person)))
        |> Enum.take(limit)

      {:ok,
       %{
         group: group.name,
         expenses:
           for e <- expenses do
             %{
               id: e.id,
               date: e.date,
               description: e.description,
               amount: decimal(e.amount_cents),
               paid_by: Map.get(names, {:user, e.paid_by}, "someone"),
               category: Map.get(cat_names, e.category_id),
               private: e.visibility == "private",
               added_from_claude: e.via == "claude",
               shares:
                 for s <- e.shares do
                   party =
                     if s.user_id,
                       do: {:user, s.user_id},
                       else: {:counterparty, s.counterparty_id}

                   %{who: Map.get(names, party, "someone"), amount: decimal(s.amount_cents)}
                 end
             }
           end
       }}
    end
  end

  defp run("suggest_settle_up", args, scope) do
    with {:ok, group} <- group(scope, args["group"]),
         {:ok, moves} <- Ledger.settle_up(scope, group.id) do
      names = names(scope, group.id)

      {:ok,
       %{
         group: group.name,
         payments:
           for m <- moves do
             %{
               from: Map.get(names, m.from, "someone"),
               to: Map.get(names, m.to, "someone"),
               amount: decimal(m.amount_cents)
             }
           end,
         note:
           if(moves == [], do: "Everyone's even.", else: "Nothing is recorded until money moves.")
       }}
    end
  end

  defp run("list_bills_to_check", _args, scope) do
    {:ok, items} = Inbox.list_items(scope)
    {:ok, groups} = Groups.list_groups(scope)
    group_names = Map.new(groups, &{&1.id, &1.name})

    {:ok,
     %{
       bills:
         for i <- items do
           p = i.proposal
           cents = p["period_cents"] || p["total_cents"]

           %{
             id: i.id,
             status: item_status(i.status),
             company: p["merchant"] || p["sender"],
             amount: cents && decimal(cents),
             due_on: i.due_on,
             past_due: p["past_due"] == true,
             group: Map.get(group_names, i.group_id),
             check_it_at: TabWeb.Endpoint.url() <> "/inbox/#{i.id}"
           }
         end
     }}
  end

  ## Writes

  defp run("add_expense", args, scope) do
    me = scope.user.id
    private? = args["private"] == true

    with {:ok, group} <- group(scope, args["group"], writable: true),
         people = people(scope, group.id),
         {:ok, cents} <- amount(args["amount"]),
         {:ok, date} <- date(args["date"]),
         {:ok, payer} <- member(people, scope, args["paid_by"] || "me"),
         {:ok, category} <- optional_category(people.categories, args["category"]),
         {:ok, split} <-
           if(private?, do: {:ok, private_split(me)}, else: split(people, scope, args["split"])),
         :ok <-
           if(private? and payer != me,
             do: {:error, "A private expense is paid by you."},
             else: :ok
           ),
         {:ok, expense} <-
           Ledger.create_expense(scope, group.id, %{
             description: args["description"],
             amount_cents: cents,
             date: date,
             paid_by: payer,
             category_id: category && category.id,
             visibility: if(private?, do: "private", else: "shared"),
             split: split
           })
           |> explain() do
      names = names(scope, group.id)

      {:ok,
       %{
         saved: true,
         id: expense.id,
         group: group.name,
         description: expense.description,
         amount: decimal(expense.amount_cents),
         date: expense.date,
         paid_by: Map.get(names, {:user, expense.paid_by}),
         shares:
           for s <- expense.shares do
             party =
               if s.user_id, do: {:user, s.user_id}, else: {:counterparty, s.counterparty_id}

             %{who: Map.get(names, party, "someone"), amount: decimal(s.amount_cents)}
           end,
         see_it_at: TabWeb.Endpoint.url() <> "/groups/#{group.id}/expenses/#{expense.id}"
       }}
    end
  end

  defp run("record_payment", args, scope) do
    with {:ok, group} <- group(scope, args["group"], writable: true),
         people = people(scope, group.id),
         {:ok, from} <- party(people, scope, args["from"] || "me"),
         {:ok, to} <- party(people, scope, args["to"]),
         {:ok, cents} <- amount(args["amount"]),
         {:ok, date} <- date(args["date"]),
         {:ok, category} <- optional_category(people.categories, args["category"]),
         {:ok, payment} <-
           Ledger.record_payment(
             scope,
             group.id,
             Map.merge(side(:from, from), side(:to, to))
             |> Map.merge(%{
               amount_cents: cents,
               date: date,
               method: args["method"],
               reference: args["reference"],
               category_id: category && category.id
             })
           )
           |> explain() do
      names = names(scope, group.id)
      to_name = Map.get(names, to, "them")

      {:ok,
       %{
         saved: true,
         id: payment.id,
         group: group.name,
         from: Map.get(names, from),
         to: to_name,
         amount: decimal(payment.amount_cents),
         status: payment.status,
         in_words:
           case payment.status do
             "pending" -> "Waiting for #{to_name} to confirm it in Tab."
             "declined" -> "Declined."
             _ -> "Counted."
           end
       }}
    end
  end

  defp run(name, _args, _scope), do: {:error, "There's no tool called #{name}."}

  ## Names

  # Members, counterparties, and categories, as `%{id:, name:}`.
  defp people(scope, group_id) do
    {:ok, members} = Groups.list_members(scope, group_id)
    {:ok, cps} = Groups.list_counterparties(scope, group_id)
    {:ok, cats} = Groups.list_categories(scope, group_id)

    %{
      members: Enum.map(members, &%{id: &1.user_id, name: &1.profile.display_name}),
      counterparties:
        cps |> Enum.filter(&is_nil(&1.deleted_at)) |> Enum.map(&%{id: &1.id, name: &1.name}),
      categories:
        cats |> Enum.filter(&is_nil(&1.deleted_at)) |> Enum.map(&%{id: &1.id, name: &1.name})
    }
  end

  # Every party's name, including people who've left, for reading history.
  defp names(scope, group_id) do
    %{members: members, counterparties: cps} = people(scope, group_id)

    Map.new(
      Enum.map(members, &{{:user, &1.id}, &1.name}) ++
        Enum.map(cps, &{{:counterparty, &1.id}, &1.name})
    )
    |> Map.put({:user, scope.user.id}, me_name(members, scope))
  end

  defp me_name(members, scope) do
    case Enum.find(members, &(&1.id == scope.user.id)) do
      %{name: name} -> name <> " (you)"
      nil -> "you"
    end
  end

  defp group(scope, name, opts \\ []) do
    {:ok, groups} = Groups.list_groups(scope)
    live = Enum.filter(groups, &is_nil(&1.deleted_at))

    result =
      case name do
        n when n in [nil, ""] ->
          case live do
            [one] -> {:ok, one}
            [] -> {:error, "You're not in any groups yet. Start one on the web."}
            _ -> {:error, "Which group? " <> choices(live)}
          end

        n when is_binary(n) ->
          pick(groups, n, "group")

        _ ->
          {:error, "Name the group. " <> choices(live)}
      end

    with {:ok, g} <- result do
      if opts[:writable] && g.deleted_at,
        do: {:error, "#{g.name} is archived, so nothing can be added to it."},
        else: {:ok, g}
    end
  end

  defp member(people, scope, who) do
    with {:ok, {:user, id}} <- party(%{people | counterparties: []}, scope, who), do: {:ok, id}
  end

  defp party(_people, _scope, who) when who in [nil, ""],
    do: {:error, "Say who: a member's name, \"me\", or an outside party's name."}

  defp party(people, scope, who) when is_binary(who) do
    if String.downcase(String.trim(who)) in ~w(me i myself you) do
      {:ok, {:user, scope.user.id}}
    else
      everyone =
        Enum.map(people.members, &Map.put(&1, :party, {:user, &1.id})) ++
          Enum.map(people.counterparties, &Map.put(&1, :party, {:counterparty, &1.id}))

      with {:ok, p} <- pick(everyone, who, "person"), do: {:ok, p.party}
    end
  end

  defp party(_, _, _), do: {:error, "Name people with text."}

  defp optional_party(_people, _scope, nil), do: {:ok, nil}
  defp optional_party(people, scope, who), do: party(people, scope, who)

  defp optional_category(_cats, c) when c in [nil, ""], do: {:ok, nil}
  defp optional_category(cats, c) when is_binary(c), do: pick(cats, c, "category")
  defp optional_category(_, _), do: {:error, "Name the category with text."}

  # By id, then by name ignoring case, then by the start of one name.
  defp pick(things, wanted, kind) do
    w = wanted |> String.trim() |> String.downcase()

    exact = Enum.filter(things, &(&1.id == wanted or String.downcase(&1.name) == w))
    starts = Enum.filter(things, &String.starts_with?(String.downcase(&1.name), w))

    case {exact, starts} do
      {[one], _} -> {:ok, one}
      {[], [one]} -> {:ok, one}
      {[_ | _] = many, _} -> {:error, "More than one #{kind} is called #{wanted}: #{ids(many)}"}
      {[], [_ | _] = many} -> {:error, "Which #{kind}? #{wanted} could be #{ids(many)}"}
      {[], []} -> {:error, "No #{kind} called #{wanted}. " <> choices(things)}
    end
  end

  defp choices([]), do: ""
  defp choices(things), do: "Choices: " <> Enum.map_join(things, ", ", & &1.name) <> "."
  defp ids(things), do: Enum.map_join(things, ", ", &"#{&1.name} (id #{&1.id})") <> "."

  ## Splits

  defp private_split(me), do: %{"type" => "equal", "entries" => [%{"user_id" => me}]}

  defp split(people, _scope, nil),
    do: {:ok, %{"type" => "equal", "entries" => Enum.map(people.members, &%{"user_id" => &1.id})}}

  defp split(people, scope, %{"type" => "tiered"} = s) do
    with {:ok, entries} <- entries(people, scope, "exact", s["with"]),
         {:ok, rest} <-
           simple_split(people, scope, s["rest"] || %{"type" => "equal", "with" => nil}) do
      {:ok, %{"type" => "tiered", "entries" => entries, "rest" => rest}}
    end
  end

  defp split(people, scope, s) when is_map(s), do: simple_split(people, scope, s)
  defp split(_, _, _), do: {:error, "split should be an object with type and with."}

  defp simple_split(people, _scope, %{"type" => "equal", "with" => w}) when w in [nil, []],
    do: split(people, nil, nil)

  defp simple_split(people, scope, %{"type" => type, "with" => with})
       when type in ~w(equal exact percentage shares) do
    with {:ok, entries} <- entries(people, scope, type, with),
         do: {:ok, %{"type" => type, "entries" => entries}}
  end

  defp simple_split(_, _, _),
    do: {:error, "Split types are equal, exact, percentage, shares, and tiered."}

  defp entries(people, scope, type, list) when is_list(list) and list != [] do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      with %{"who" => who} <- entry,
           {:ok, party} <- party(people, scope, who),
           {:ok, value} <- entry_value(type, entry["value"]) do
        key = if elem(party, 0) == :user, do: "user_id", else: "counterparty_id"
        e = %{key => elem(party, 1)}
        e = if is_nil(value), do: e, else: Map.put(e, "value", value)
        {:cont, {:ok, acc ++ [e]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, "Each split entry needs who."}}
      end
    end)
  end

  defp entries(_, _, _, _), do: {:error, "The split needs at least one person in with."}

  defp entry_value("equal", _), do: {:ok, nil}

  defp entry_value("exact", v), do: amount(v)

  defp entry_value("percentage", v) do
    case Decimal.parse(to_string(v || "")) do
      {d, ""} -> {:ok, Decimal.to_string(d)}
      _ -> {:error, "Percentages are numbers like \"60\"."}
    end
  end

  defp entry_value("shares", v) do
    case to_int(v, nil) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, "Shares are whole numbers like 2."}
    end
  end

  ## Values

  defp amount(v) when is_number(v), do: amount(to_string(v))

  defp amount(v) do
    case Format.parse_money(v) do
      {:ok, cents} when cents > 0 -> {:ok, cents}
      _ -> {:error, ~s(Amounts look like "43.10", more than zero, at most two decimal places.)}
    end
  end

  defp date(nil), do: {:ok, Date.utc_today()}

  defp date(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, d} -> {:ok, d}
      _ -> {:error, "Dates look like 2026-10-16."}
    end
  end

  defp date(_), do: {:error, "Dates look like 2026-10-16."}

  defp to_int(n, _) when is_integer(n), do: n

  defp to_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp to_int(_, default), do: default

  defp decimal(cents) do
    sign = if cents < 0, do: "-", else: ""
    c = abs(cents)
    "#{sign}#{div(c, 100)}.#{c |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp balance_row(r, names) do
    %{
      owes: Map.get(names, r.debtor, "someone"),
      owed: Map.get(names, r.creditor, "someone"),
      amount: decimal(r.amount_cents)
    }
  end

  defp involves?(e, {:user, id}),
    do: e.paid_by == id or Enum.any?(e.shares, &(&1.user_id == id))

  defp involves?(e, {:counterparty, id}), do: Enum.any?(e.shares, &(&1.counterparty_id == id))

  defp side(:from, {:user, id}), do: %{from_user_id: id}
  defp side(:from, {:counterparty, id}), do: %{from_counterparty_id: id}
  defp side(:to, {:user, id}), do: %{to_user_id: id}
  defp side(:to, {:counterparty, id}), do: %{to_counterparty_id: id}

  defp item_status(s) when s in ~w(ready unreadable), do: "ready to check"
  defp item_status("reading"), do: "being read"
  defp item_status("waiting"), do: "waiting to be read"
  defp item_status(s), do: s

  ## Errors

  defp explain({:ok, _} = ok), do: ok

  defp explain({:error, %Ecto.Changeset{} = cs}) do
    message =
      cs
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

    {:error, "Tab didn't save it: " <> message}
  end

  defp explain({:error, reason}),
    do: {:error, "Tab didn't save it: " <> (describe(reason) || "it was refused")}

  defp describe(:forbidden), do: "you can't do that in this group"
  defp describe(:not_found), do: "it isn't there"
  defp describe({:invalid, message}), do: message
  defp describe(nil), do: nil
  defp describe(other), do: inspect(other)
end
