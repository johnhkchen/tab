defmodule TabWeb.SplitEditor do
  @moduledoc """
  Who's in and how to split it, for recurring bills and temporary splits.
  Simpler than the add-expense form's editor: no tiered splits, and `exact`
  only where the page allows it, because these splits apply to bills not yet
  known.

  The state is `%{type:, included: %{key => bool}, values: %{key => text}}`,
  keyed by `TabWeb.GroupData.party_key/1`. Form fields are `split_type`,
  `in[key]`, and `value[key]`.
  """
  use Phoenix.Component

  alias Tab.Ledger.Split
  alias TabWeb.{Format, GroupData}

  @labels %{
    "equal" => "Evenly",
    "exact" => "By exact amounts",
    "percentage" => "By percentages",
    "shares" => "By shares (2:1:1)"
  }

  attr :data, :any, required: true
  attr :state, :map, required: true
  attr :types, :list, default: ~w(equal percentage shares)
  attr :error, :string, default: nil
  attr :preview, :map, default: %{}, doc: "key => cents, for a sample amount"

  def split_fields(assigns) do
    assigns = assign(assigns, :options, Enum.map(assigns.types, &{@labels[&1], &1}))

    ~H"""
    <TabWeb.CoreComponents.input
      name="split_type"
      id="split_type"
      type="select"
      label="Split"
      options={@options}
      value={@state.type}
    />
    <ul class="mt-2 divide-y divide-line" id="split-parties">
      <li
        :for={{label, key} <- GroupData.party_options(@data)}
        class="flex flex-wrap items-center gap-3 py-2"
      >
        <label class="flex min-w-36 flex-1 items-center gap-3">
          <input type="hidden" name={"in[#{key}]"} value="false" />
          <input
            type="checkbox"
            class="tab-check"
            name={"in[#{key}]"}
            value="true"
            id={"in-#{key}"}
            checked={@state.included[key]}
          />
          <span>{label}</span>
        </label>
        <input
          :if={@state.included[key] && @state.type != "equal"}
          name={"value[#{key}]"}
          value={@state.values[key]}
          class="tab-field w-24"
          inputmode="decimal"
          placeholder={placeholder(@state.type)}
          aria-label={"#{placeholder(@state.type)} for #{label}"}
        />
        <TabWeb.CoreComponents.money
          :if={@state.included[key] && Map.has_key?(@preview, key)}
          cents={@preview[key]}
          class="w-24 text-right text-ink-soft"
        />
      </li>
    </ul>
    <TabWeb.CoreComponents.error :if={@error}>{@error}</TabWeb.CoreComponents.error>
    """
  end

  defp placeholder("exact"), do: "$"
  defp placeholder("percentage"), do: "%"
  defp placeholder(_), do: "shares"

  @doc "Everyone who's a member starts in, evenly."
  def new_state(data) do
    keys = Enum.map(GroupData.party_options(data), &elem(&1, 1))

    %{
      type: "equal",
      included: Map.new(keys, &{&1, String.starts_with?(&1, "user:")}),
      values: %{}
    }
  end

  @doc "The state for an existing split."
  def state(nil, data), do: new_state(data)

  def state(%{"type" => type, "entries" => entries}, data) do
    keys = Enum.map(GroupData.party_options(data), &elem(&1, 1))
    in_split = MapSet.new(entries, &key/1)

    %{
      type: type,
      included: Map.new(keys, &{&1, MapSet.member?(in_split, &1)}),
      values: Map.new(entries, &{key(&1), display(type, &1["value"])})
    }
  end

  @doc "Reads the split fields out of a form's params."
  def read(state, params) do
    %{
      type: params["split_type"] || state.type,
      included:
        Map.merge(state.included, Map.new(params["in"] || %{}, fn {k, v} -> {k, v == "true"} end)),
      values: Map.merge(state.values, params["value"] || %{})
    }
  end

  @doc "The split the state describes, or `{:error, message}`."
  def build(state, data) do
    keys = for {_, key} <- GroupData.party_options(data), state.included[key], do: key

    split =
      case state.type do
        "equal" ->
          {:ok, %{"type" => "equal", "entries" => Enum.map(keys, &entry/1)}}

        type when type in ~w(exact percentage shares) ->
          Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
            case value(type, String.trim(state.values[key] || "")) do
              {:ok, v} -> {:cont, {:ok, [Map.put(entry(key), "value", v) | acc]}}
              :error -> {:halt, {:error, error_for(type)}}
            end
          end)
          |> case do
            {:ok, es} -> {:ok, %{"type" => type, "entries" => Enum.reverse(es)}}
            error -> error
          end

        _ ->
          {:error, "pick how to split it"}
      end

    with {:ok, %{"entries" => [_ | _]} = split} <- split,
         {:ok, _} <- Split.weights(split, sample(split)) do
      {:ok, split}
    else
      {:ok, _} -> {:error, "pick at least one person"}
      error -> error
    end
  end

  @doc "Each person's cents of `amount` under the state, for a preview; `%{}` if it doesn't add up."
  def preview(state, data, amount) when is_integer(amount) and amount > 0 do
    with {:ok, split} <- build(state, data),
         {:ok, shares} <- Split.compute(split, amount) do
      Map.new(shares, fn {party, cents} -> {GroupData.party_key(party), cents} end)
    else
      _ -> %{}
    end
  end

  def preview(_, _, _), do: %{}

  # Exact amounts need a total to check against: their own sum.
  defp sample(%{"type" => "exact", "entries" => es}),
    do: es |> Enum.map(& &1["value"]) |> Enum.sum()

  defp sample(_), do: nil

  defp value("exact", text), do: Format.parse_money(text)
  defp value("percentage", ""), do: :error
  defp value("percentage", text), do: {:ok, String.trim_trailing(text, "%")}

  defp value("shares", text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp error_for("exact"), do: "give everyone in the split an amount, like 12.50"
  defp error_for("percentage"), do: "give everyone in the split a percentage"
  defp error_for("shares"), do: "give everyone in the split a whole number of shares, like 2"

  defp entry("user:" <> id), do: %{"user_id" => id}
  defp entry("counterparty:" <> id), do: %{"counterparty_id" => id}

  defp key(%{"user_id" => id}), do: "user:" <> id
  defp key(%{"counterparty_id" => id}), do: "counterparty:" <> id

  defp display("exact", cents) when is_integer(cents), do: Format.amount_input(cents)
  defp display(_, nil), do: ""
  defp display(_, v), do: to_string(v)

  @doc "A short description of a split for lists: \"Evenly: Priya, Sam\"."
  def describe(%{"type" => type, "entries" => entries}, data) do
    names =
      Enum.map_join(entries, ", ", fn e ->
        name = GroupData.name(data, party(e))

        case {type, e["value"]} do
          {"equal", _} -> name
          {"percentage", v} -> "#{name} #{v}%"
          {"shares", v} -> "#{name} ×#{v}"
          {"exact", v} -> "#{name} #{Format.money(v)}"
        end
      end)

    "#{@labels[type]}: #{names}"
  end

  def describe(_, _), do: "Evenly among everyone"

  defp party(%{"user_id" => id}), do: {:user, id}
  defp party(%{"counterparty_id" => id}), do: {:counterparty, id}
end
