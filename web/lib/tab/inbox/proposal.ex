defmodule Tab.Inbox.Proposal do
  @moduledoc """
  Checks what the reader sent back before anyone sees it
  (docs/specification.md, "The reader"). Anything that doesn't pass comes back
  blank, never guessed: the reader only ever fills in a form a person checks.

  Input is the reader's JSON (string keys). Output keeps only known fields,
  with dates as ISO strings so it stores as jsonb unchanged. `period_cents` is
  what this bill adds on its own, without a balance carried from earlier
  bills; the form fills that in, so a carried balance never counts twice.
  """

  @types ~w(utility receipt subscription rent travel phone other)
  @max_cents 100_000_000
  @window_days 730

  @doc "The checked proposal. `today` sets the two-year window for dates."
  def validate(raw, today \\ Date.utc_today())

  def validate(raw, today) when is_map(raw) do
    items = line_items(raw["line_items"])
    total = cents(raw["total_cents"])

    %{
      "doc_type" => if(raw["doc_type"] in @types, do: raw["doc_type"], else: "other"),
      "merchant" => text(raw["merchant"], 120),
      "total_cents" => total,
      "date" => date(raw["date"], today),
      "due_on" => date(raw["due_on"], today),
      "period_start" => date(raw["period_start"], today),
      "period_end" => date(raw["period_end"], today),
      "account_hint" => hint(raw["account_hint"]),
      "tax_cents" => cents(raw["tax_cents"]),
      "tip_cents" => cents(raw["tip_cents"]),
      "current_cents" => cents(raw["current_cents"]),
      "previous_cents" => cents(raw["previous_cents"]),
      "past_due" => raw["past_due"] == true,
      "line_items" => if(adds_up?(items, raw, total), do: items, else: [])
    }
    |> period_in_order()
    |> this_period()
  end

  def validate(_, today), do: validate(%{}, today)

  @doc "A proposal with nothing in it, for documents nobody could read."
  def blank, do: validate(%{})

  defp cents(n) when is_integer(n) and n > 0 and n < @max_cents, do: n
  defp cents(_), do: nil

  defp text(s, max) when is_binary(s) do
    case s |> String.replace(~r/[\x00-\x1f]/u, " ") |> String.trim() do
      "" -> nil
      t -> String.slice(t, 0, max)
    end
  end

  defp text(_, _), do: nil

  defp hint(s) when is_binary(s) do
    case Regex.run(~r/(\d{4})\D*$/, s) do
      [_, last4] -> last4
      _ -> nil
    end
  end

  defp hint(_), do: nil

  defp date(s, today) when is_binary(s) do
    with {:ok, d} <- Date.from_iso8601(s),
         true <- abs(Date.diff(d, today)) <= @window_days do
      Date.to_iso8601(d)
    else
      _ -> nil
    end
  end

  defp date(_, _), do: nil

  defp line_items(items) when is_list(items) do
    items
    |> Enum.take(50)
    |> Enum.flat_map(fn
      %{"description" => d, "cents" => c} ->
        case {text(d, 120), cents(c)} do
          {desc, n} when is_binary(desc) and is_integer(n) ->
            [%{"description" => desc, "cents" => n}]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp line_items(_), do: []

  # Line items plus tax and tip within a dollar of the total, or they go.
  defp adds_up?([], _, _), do: true
  defp adds_up?(_, _, nil), do: false

  defp adds_up?(items, raw, total) do
    sum =
      Enum.sum(Enum.map(items, & &1["cents"])) + (cents(raw["tax_cents"]) || 0) +
        (cents(raw["tip_cents"]) || 0)

    abs(sum - total) <= 100
  end

  # What this bill adds, without a balance carried from earlier bills: the
  # printed current charges, else the total minus the carried balance.
  defp this_period(%{"current_cents" => c} = p) when is_integer(c),
    do: Map.put(p, "period_cents", c)

  defp this_period(%{"total_cents" => t, "previous_cents" => prev} = p)
       when is_integer(t) and is_integer(prev) and t > prev,
       do: Map.put(p, "period_cents", t - prev)

  defp this_period(p), do: Map.put(p, "period_cents", p["total_cents"])

  defp period_in_order(%{"period_start" => from, "period_end" => to} = p)
       when is_binary(from) and is_binary(to) do
    if from <= to, do: p, else: %{p | "period_start" => nil, "period_end" => nil}
  end

  defp period_in_order(%{"period_start" => from, "period_end" => to} = p)
       when is_nil(from) or is_nil(to),
       do: %{p | "period_start" => nil, "period_end" => nil}
end
