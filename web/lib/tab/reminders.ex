defmodule Tab.Reminders do
  @moduledoc """
  Reminder drafts for money someone owes you (docs/specification.md,
  "Reminder drafts"): a Venmo note, a text, and an email, from the same
  facts. Plain string templates over data already in the ledger: no AI, no
  network, nothing sent. People copy a draft and send it themselves.
  """
  import TabWeb.Format, only: [money: 1]

  @labels %{
    "venmo" => "Venmo",
    "zelle" => "Zelle",
    "cashapp" => "Cash App",
    "paypal" => "PayPal",
    "cash" => "cash",
    "check" => "a check",
    "other" => "other"
  }

  @doc """
  Drafts for one balance. `facts`:

    * `:to` and `:from`: names (the person who owes, and you)
    * `:group`: the group's name
    * `:amount_cents`: what they owe you
    * `:items`: open bills, oldest first, as `%{description:, date:}`
    * `:methods`: your payment methods, `%{"kind" => ..., "handle" => ...}`
    * `:link`: a statement link, or `nil`

  Returns `%{venmo: text, text: text, email: %{subject: text, body: text}}`.
  """
  def drafts(facts) do
    %{venmo: venmo(facts), text: text(facts), email: email(facts)}
  end

  defp venmo(f) do
    [f.group, ": ", for_what(f.items, 2), " ", money(f.amount_cents)]
    |> IO.iodata_to_binary()
    |> String.slice(0, 280)
  end

  defp text(f) do
    [
      "Hi #{f.to}, your share of #{f.group} bills comes to #{money(f.amount_cents)}",
      if(f.items != [], do: " (#{for_what(f.items, 3)})", else: ""),
      ".",
      case how_to_pay(f.methods) do
        nil -> ""
        how -> " #{how}."
      end,
      if(f.link, do: " The details: #{f.link}", else: ""),
      " Thanks!"
    ]
    |> IO.iodata_to_binary()
  end

  defp email(f) do
    subject = "#{f.group}: #{money(f.amount_cents)} to settle up"

    lines =
      [
        "Hi #{f.to},",
        "",
        "Your share of #{f.group} bills comes to #{money(f.amount_cents)}."
      ] ++
        case f.items do
          [] ->
            []

          items ->
            [
              "",
              "Still open:"
              | Enum.map(Enum.take(items, 10), &"- #{&1.description} (#{date(&1.date)})")
            ] ++ more(items, 10)
        end ++
        case how_to_pay(f.methods) do
          nil -> []
          how -> ["", how <> "."]
        end ++
        if(f.link, do: ["", "Everything for the month, line by line: #{f.link}"], else: []) ++
        ["", "Thanks,", f.from]

    %{subject: subject, body: Enum.join(lines, "\n")}
  end

  defp for_what([], _), do: "bills"

  defp for_what(items, n) do
    names = items |> Enum.map(& &1.description) |> Enum.uniq()
    shown = Enum.take(names, n)

    case length(names) - length(shown) do
      0 -> Enum.join(shown, ", ")
      rest -> Enum.join(shown, ", ") <> " and #{rest} more"
    end
  end

  defp more(items, n) when length(items) > n, do: ["- and #{length(items) - n} more"]
  defp more(_, _), do: []

  defp how_to_pay([]), do: nil
  defp how_to_pay(nil), do: nil

  defp how_to_pay(methods) do
    ways =
      Enum.map(methods, fn m ->
        label = Map.get(@labels, m["kind"], m["kind"])
        handle = String.trim(m["handle"] || "")
        if handle == "", do: label, else: "#{label} #{handle}"
      end)

    "You can pay me by " <> join_or(ways)
  end

  defp join_or([one]), do: one
  defp join_or([a, b]), do: "#{a} or #{b}"
  defp join_or(list), do: Enum.join(Enum.drop(list, -1), ", ") <> ", or " <> List.last(list)

  defp date(%Date{} = d), do: Calendar.strftime(d, "%b %-d")
end
