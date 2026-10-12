defmodule Tab.Bills.Suggest do
  @moduledoc """
  Which split the add-expense form suggests (docs/specification.md, "Which
  split the form suggests"), and the splits the temporary-splits page proposes.
  Pure: it takes splits and overrides as data and returns a split to show.
  Nothing here saves anything.

  Overrides are maps (or structs) with `category_id`, `effective_from`,
  `effective_until` (`nil` for no end), and `split`.
  """
  alias Tab.Bills.Dates
  alias Tab.Ledger.Split

  @type why ::
          nil
          | {:override, map}
          | {:prorated, [{map, pos_integer}], pos_integer}

  @doc """
  The split to suggest for a bill, and why: `{split, why}`.

  `bill` has `category_id`, `date`, `period` (`{from, to}` or `nil`), and
  `amount_cents` (`nil` until typed; only an `exact` normal split needs it).
  """
  @spec suggest(map, [map], map) :: {map, why}
  def suggest(normal, overrides, bill) do
    applicable = Enum.filter(overrides, &for_category?(&1, bill[:category_id]))

    case bill[:period] do
      {from, to} when is_struct(from, Date) and is_struct(to, Date) ->
        prorate(normal, applicable, {from, to}, bill[:amount_cents])

      _ ->
        case Enum.find(applicable, &covers?(&1, bill[:date])) do
          nil -> {normal, nil}
          o -> {o.split, {:override, o}}
        end
    end
  end

  defp for_category?(%{category_id: nil}, _), do: true
  defp for_category?(%{category_id: id}, id), do: true
  defp for_category?(_, _), do: false

  defp covers?(_, nil), do: false

  defp covers?(o, date) do
    Date.compare(date, o.effective_from) != :lt and
      (o.effective_until == nil or Date.compare(date, o.effective_until) != :gt)
  end

  defp prorate(normal, overrides, period, amount) do
    total = Dates.days(period)

    pieces =
      for o <- overrides,
          d = Dates.overlap(period, {o.effective_from, o.effective_until}),
          d > 0,
          do: {o, d}

    covered = pieces |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    cond do
      pieces == [] ->
        {normal, nil}

      covered >= total and match?([_], pieces) ->
        [{o, _}] = pieces
        {o.split, {:override, o}}

      true ->
        parts = [{normal, total - covered} | Enum.map(pieces, fn {o, d} -> {o.split, d} end)]

        case blend(parts, amount) do
          {:ok, split} -> {split, {:prorated, pieces, total}}
          :error -> {normal, nil}
        end
    end
  end

  @doc """
  Blends splits by days: `[{split, days}]` into one `shares` split where each
  person's weight is the sum of (their fraction under that split) × (days).
  """
  def blend(parts, amount \\ nil) do
    parts = Enum.reject(parts, fn {_, days} -> days <= 0 end)

    with {:ok, weighted} <- collect(parts, amount) do
      lcm = weighted |> Enum.map(&elem(&1, 1)) |> Enum.reduce(1, &lcm/2)

      {order, sums} =
        Enum.reduce(weighted, {[], %{}}, fn {weights, total, days}, acc ->
          Enum.reduce(weights, acc, fn {party, w}, {order, sums} ->
            order = if Map.has_key?(sums, party), do: order, else: [party | order]

            {order,
             Map.update(
               sums,
               party,
               w * div(lcm, total) * days,
               &(&1 + w * div(lcm, total) * days)
             )}
          end)
        end)

      shares(Enum.reverse(order), sums)
    end
  end

  defp collect(parts, amount) do
    Enum.reduce_while(parts, {:ok, []}, fn {split, days}, {:ok, acc} ->
      case Split.weights(split, amount) do
        {:ok, weights} ->
          total = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()
          if total > 0, do: {:cont, {:ok, [{weights, total, days} | acc]}}, else: {:halt, :error}

        {:error, _} ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  @doc """
  The combined split for days two temporary splits share: each person's weight
  is their fraction under one times their fraction under the other, so anyone
  left out of either stays out. `nil` when nobody is in both.
  """
  def combine(a, b) do
    with {:ok, wa} <- Split.weights(a),
         {:ok, wb} <- Split.weights(b) do
      wb = Map.new(wb)

      products =
        for {party, w} <- wa, w > 0, Map.get(wb, party, 0) > 0, do: {party, w * wb[party]}

      case shares(Enum.map(products, &elem(&1, 0)), Map.new(products)) do
        {:ok, split} -> split
        :error -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  `split` with `party` taken out and their share spread over everyone else by
  their existing ratios. An even split stays even. `nil` when nobody is left or
  the split depends on the amount.
  """
  def without(%{"type" => "equal", "entries" => entries}, party) do
    case Enum.reject(entries, &(entry_party(&1) == party)) do
      [] -> nil
      rest -> %{"type" => "equal", "entries" => rest}
    end
  end

  def without(split, party) do
    case Split.weights(split) do
      {:ok, weights} ->
        rest = for {p, w} <- weights, p != party, w > 0, do: {p, w}

        case shares(Enum.map(rest, &elem(&1, 0)), Map.new(rest)) do
          {:ok, split} -> split
          :error -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc "An even split among `parties`."
  def equal(parties), do: %{"type" => "equal", "entries" => Enum.map(parties, &entry/1)}

  # A `shares` split in lowest terms; people at zero drop out.
  defp shares(order, sums) do
    kept = for p <- order, Map.get(sums, p, 0) > 0, do: {p, sums[p]}
    gcd = kept |> Enum.map(&elem(&1, 1)) |> Enum.reduce(0, &Integer.gcd/2)

    case kept do
      [] ->
        :error

      _ ->
        {:ok,
         %{
           "type" => "shares",
           "entries" => Enum.map(kept, fn {p, w} -> Map.put(entry(p), "value", div(w, gcd)) end)
         }}
    end
  end

  defp lcm(a, b), do: div(a * b, Integer.gcd(a, b))

  defp entry({:user, id}), do: %{"user_id" => id}
  defp entry({:counterparty, id}), do: %{"counterparty_id" => id}

  defp entry_party(%{"user_id" => id}), do: {:user, id}
  defp entry_party(%{"counterparty_id" => id}), do: {:counterparty, id}
end
