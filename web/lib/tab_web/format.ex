defmodule TabWeb.Format do
  @moduledoc """
  Money in and out of the UI. The ledger keeps whole cents; people type and
  read dollars (or whichever currency `TAB_CURRENCY` names, one per instance).
  """

  @symbols %{"USD" => "$", "CAD" => "$", "AUD" => "$", "NZD" => "$", "EUR" => "€", "GBP" => "£"}

  def currency, do: Application.get_env(:tab, :currency, "USD")

  @doc """
  Formats cents for reading: `money(123456)` is `"$1,234.56"`.
  """
  def money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "−", else: ""
    cents = abs(cents)
    whole = cents |> div(100) |> Integer.to_string() |> group_thousands()
    fraction = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    case Map.fetch(@symbols, currency()) do
      {:ok, symbol} -> "#{sign}#{symbol}#{whole}.#{fraction}"
      :error -> "#{sign}#{whole}.#{fraction} #{currency()}"
    end
  end

  @doc """
  Cents for an editing field: `amount_input(1250)` is `"12.50"`.
  """
  def amount_input(nil), do: ""

  def amount_input(cents) when is_integer(cents),
    do: :erlang.float_to_binary(cents / 100, decimals: 2)

  @doc """
  Reads what someone typed as an amount: `"12.5"`, `"$1,200"`, `"0.99"`.
  Returns `{:ok, cents}` or `:error`. More than two decimal places is an error,
  not a rounding.
  """
  def parse_money(text) when is_binary(text) do
    cleaned = text |> String.trim() |> String.replace(~r/[\s,]/u, "") |> String.trim_leading("$")

    case Regex.run(~r/\A(\d+)(?:\.(\d{0,2}))?\z/, cleaned) do
      [_, whole] ->
        {:ok, String.to_integer(whole) * 100}

      [_, whole, ""] ->
        {:ok, String.to_integer(whole) * 100}

      [_, whole, frac] ->
        {:ok,
         String.to_integer(whole) * 100 + String.to_integer(String.pad_trailing(frac, 2, "0"))}

      nil ->
        :error
    end
  end

  def parse_money(_), do: :error

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
