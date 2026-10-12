defmodule TabWeb.ExpenseLive.Form do
  @moduledoc """
  Add or edit an expense: what it was, how much, who paid, who's in, and how
  to split it. Each person's share is worked out as you type, with the same
  `Tab.Ledger.Split` the ledger uses, so what you see is what gets saved.
  """
  use TabWeb, :live_view

  alias Tab.Ledger
  alias Tab.Ledger.Split
  alias TabWeb.{Format, GroupData}

  @types [
    {"Evenly", "equal"},
    {"By exact amounts", "exact"},
    {"By percentages", "percentage"},
    {"By shares (2:1:1)", "shares"},
    {"Fixed amounts first, then the rest", "tiered"}
  ]
  @rest_types [{"evenly", "equal"}, {"by percentages", "percentage"}, {"by shares", "shares"}]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={back_path(@data, @expense)}>
        {if @expense, do: @expense.description, else: @data.group.name}
      </.back>
      <.header>{if @expense, do: "Edit expense", else: "Add an expense"}</.header>

      <form id="expense_form" phx-change="change" phx-submit="save" class="space-y-6">
        <.card>
          <.input
            name="expense[description]"
            id="expense_description"
            label="What was it?"
            value={@f["description"]}
            errors={@errors[:description] || []}
            placeholder="Groceries, electric bill, dinner…"
            required
          />
          <div class="grid grid-cols-1 gap-x-4 sm:grid-cols-2">
            <.input
              name="expense[amount]"
              id="expense_amount"
              label="How much?"
              value={@f["amount"]}
              errors={@errors[:amount_cents] || []}
              inputmode="decimal"
              placeholder="0.00"
              required
            />
            <.input
              name="expense[date]"
              id="expense_date"
              type="date"
              label="When?"
              value={@f["date"]}
              errors={@errors[:date] || []}
              required
            />
            <.input
              name="expense[category_id]"
              id="expense_category"
              type="select"
              label="Category"
              options={Enum.map(@data.categories, &{&1.name, &1.id})}
              prompt="No category"
              value={@f["category_id"]}
            />
            <.input
              :if={@f["private"] != "true"}
              name="expense[paid_by]"
              id="expense_paid_by"
              type="select"
              label="Who paid?"
              options={Enum.map(@data.members, &{GroupData.name_user(@data, &1.user_id), &1.user_id})}
              value={@f["paid_by"]}
              errors={@errors[:paid_by] || []}
            />
          </div>
          <.input
            name="expense[private]"
            id="expense_private"
            type="checkbox"
            label="Only me: keep this private, out of the group's balances"
            value={@f["private"]}
          />
        </.card>

        <.card :if={@f["private"] != "true"} title="Who's in, and how to split it">
          <.input
            name="expense[split_type]"
            id="expense_split_type"
            type="select"
            label="Split"
            options={@types}
            value={@f["split_type"]}
          />
          <.input
            :if={@f["split_type"] == "tiered"}
            name="expense[rest_type]"
            id="expense_rest_type"
            type="select"
            label="Then split what's left"
            options={@rest_types}
            value={@f["rest_type"]}
          />

          <ul class="mt-2 divide-y divide-line" id="participants">
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
                  checked={@included[key]}
                />
                <span>{label}</span>
              </label>
              <input
                :if={@included[key] && @f["split_type"] == "tiered"}
                name={"fixed[#{key}]"}
                value={@fixed[key]}
                class="tab-field w-24"
                inputmode="decimal"
                placeholder="$ first"
                aria-label={"Fixed amount for #{label}"}
              />
              <input
                :if={@included[key] && value_column?(@f)}
                name={"value[#{key}]"}
                value={@values[key]}
                class="tab-field w-24"
                inputmode="decimal"
                placeholder={value_placeholder(@f)}
                aria-label={"#{value_placeholder(@f)} for #{label}"}
              />
              <.money
                :if={@included[key]}
                cents={Map.get(@preview_by_key, key, 0)}
                class="w-24 text-right font-semibold"
              />
            </li>
          </ul>
          <.error :if={@split_error}>{@split_error}</.error>
          <p :if={@data.counterparties == []} class="mt-3 text-sm text-ink-soft">
            Splitting with someone outside the group, like a landlord or the neighbors?
            Add them under <.link navigate={~p"/groups/#{@data.group}/members"} class="underline">People</.link>.
          </p>
        </.card>

        <div class="flex flex-wrap gap-2">
          <.button phx-disable-with="Saving…">{if @expense, do: "Save changes", else: "Add it"}</.button>
          <.button variant="soft" navigate={back_path(@data, @expense)}>Cancel</.button>
        </div>
      </form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"group_id" => group_id} = params, _session, socket) do
    scope = socket.assigns.current_scope
    data = GroupData.load!(scope, group_id)
    if data.archived?, do: raise(GroupData.NotFound)

    {expense, state} =
      case params do
        %{"id" => id} ->
          expense = fetch_expense!(scope, data, id)
          {expense, state_from(expense, data)}

        _ ->
          {nil, new_state(data)}
      end

    {:ok,
     socket
     |> assign(data: data, expense: expense, errors: %{}, types: @types, rest_types: @rest_types)
     |> assign(state)
     |> assign(page_title: if(expense, do: "Edit expense", else: "Add an expense"))
     |> preview()}
  end

  defp fetch_expense!(scope, data, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, %{group_id: group_id} = e} when group_id == data.group.id <-
           Ledger.get_expense(scope, id),
         nil <- e.deleted_at do
      e
    else
      _ -> raise GroupData.NotFound
    end
  end

  defp new_state(data) do
    keys = Enum.map(GroupData.party_options(data), &elem(&1, 1))

    %{
      f: %{
        "description" => "",
        "amount" => "",
        "date" => Date.to_iso8601(Date.utc_today()),
        "category_id" => "",
        "paid_by" => data.me,
        "private" => "false",
        "split_type" => "equal",
        "rest_type" => "equal"
      },
      # Members start in; counterparties start out.
      included: Map.new(keys, &{&1, String.starts_with?(&1, "user:")}),
      values: %{},
      fixed: %{}
    }
  end

  defp state_from(e, data) do
    split = e.split
    {type, entries, rest} = {split["type"], split["entries"] || [], split["rest"]}
    value_entries = if type == "tiered", do: (rest || %{})["entries"] || [], else: entries
    value_type = if type == "tiered", do: (rest || %{})["type"], else: type
    keys = Enum.map(GroupData.party_options(data), &elem(&1, 1))
    in_split = MapSet.new(entries ++ value_entries, &entry_key/1)

    %{
      f: %{
        "description" => e.description,
        "amount" => Format.amount_input(e.amount_cents),
        "date" => Date.to_iso8601(e.date),
        "category_id" => e.category_id || "",
        "paid_by" => e.paid_by,
        "private" => to_string(e.visibility == "private"),
        "split_type" => type,
        "rest_type" => if(type == "tiered", do: value_type, else: "equal")
      },
      included: Map.new(keys, &{&1, MapSet.member?(in_split, &1)}),
      values: Map.new(value_entries, &{entry_key(&1), display_value(value_type, &1["value"])}),
      fixed:
        if(type == "tiered",
          do: Map.new(entries, &{entry_key(&1), Format.amount_input(&1["value"])}),
          else: %{}
        )
    }
  end

  defp entry_key(%{"user_id" => id}), do: "user:" <> id
  defp entry_key(%{"counterparty_id" => id}), do: "counterparty:" <> id

  defp display_value("exact", cents) when is_integer(cents), do: Format.amount_input(cents)
  defp display_value(_, nil), do: ""
  defp display_value(_, v), do: to_string(v)

  @impl true
  def handle_event("change", params, socket) do
    {:noreply, socket |> assign(read(params, socket.assigns)) |> preview()}
  end

  def handle_event("save", params, socket) do
    socket = socket |> assign(read(params, socket.assigns)) |> preview()
    scope = socket.assigns.current_scope

    with {:ok, attrs} <- attrs(socket.assigns),
         {:ok, expense} <- persist(scope, socket.assigns, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, if(socket.assigns.expense, do: "Saved.", else: "Added."))
       |> push_navigate(to: ~p"/groups/#{socket.assigns.data.group}/expenses/#{expense}")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, errors: errors(changeset), split_error: split_error(changeset, socket))}

      {:error, {:field, field, message}} ->
        {:noreply, assign(socket, errors: %{field => [message]})}

      {:error, :split} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp persist(scope, %{expense: nil, data: data}, attrs),
    do: Ledger.create_expense(scope, data.group.id, attrs)

  defp persist(scope, %{expense: e}, attrs), do: Ledger.update_expense(scope, e.id, attrs)

  defp read(params, assigns) do
    f = Map.merge(assigns.f, Map.take(params["expense"] || %{}, Map.keys(assigns.f)))

    %{
      f: f,
      included:
        Map.merge(
          assigns.included,
          Map.new(params["in"] || %{}, fn {k, v} -> {k, v == "true"} end)
        ),
      values: Map.merge(assigns.values, params["value"] || %{}),
      fixed: Map.merge(assigns.fixed, params["fixed"] || %{})
    }
  end

  defp preview(socket) do
    with {:ok, amount} <- Format.parse_money(socket.assigns.f["amount"]),
         true <- amount > 0,
         {:ok, split} <- build_split(socket.assigns),
         {:ok, shares} <- Split.compute(split, amount) do
      assign(socket,
        preview_by_key:
          Map.new(shares, fn {party, cents} -> {GroupData.party_key(party), cents} end),
        split_error: nil
      )
    else
      {:error, reason} when is_binary(reason) ->
        assign(socket, preview_by_key: %{}, split_error: reason)

      _ ->
        assign(socket, preview_by_key: %{}, split_error: nil)
    end
  end

  # -- Building the split ----------------------------------------------------------

  defp build_split(%{f: %{"private" => "true"}, data: data}) do
    {:ok, %{"type" => "equal", "entries" => [%{"user_id" => data.me}]}}
  end

  defp build_split(%{f: f} = assigns) do
    parties = included_parties(assigns)

    case f["split_type"] do
      "tiered" ->
        fixed =
          for key <- parties, (text = assigns.fixed[key] || "") |> String.trim() != "" do
            {key, text}
          end

        with {:ok, fixed_entries} <- entries(fixed, "exact"),
             {:ok, rest} <- simple(f["rest_type"], parties, assigns) do
          {:ok, %{"type" => "tiered", "entries" => fixed_entries, "rest" => rest}}
        end

      type ->
        simple(type, parties, assigns)
    end
  end

  defp simple("equal", parties, _),
    do: {:ok, %{"type" => "equal", "entries" => Enum.map(parties, &entry/1)}}

  defp simple(type, parties, assigns) when type in ~w(exact percentage shares) do
    with {:ok, es} <- entries(Enum.map(parties, &{&1, assigns.values[&1] || ""}), type) do
      {:ok, %{"type" => type, "entries" => es}}
    end
  end

  defp simple(_, _, _), do: {:error, "pick how to split it"}

  defp entries(pairs, type) do
    Enum.reduce_while(pairs, {:ok, []}, fn {key, text}, {:ok, acc} ->
      case value(type, String.trim(text)) do
        {:ok, v} -> {:cont, {:ok, [Map.put(entry(key), "value", v) | acc]}}
        :error -> {:halt, {:error, error_for(type)}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

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

  defp included_parties(assigns) do
    for {_, key} <- GroupData.party_options(assigns.data), assigns.included[key], do: key
  end

  defp value_column?(f),
    do:
      f["split_type"] in ~w(exact percentage shares) or
        (f["split_type"] == "tiered" and f["rest_type"] in ~w(percentage shares))

  defp value_placeholder(%{"split_type" => "exact"}), do: "$"
  defp value_placeholder(%{"split_type" => "percentage"}), do: "%"
  defp value_placeholder(%{"split_type" => "shares"}), do: "shares"
  defp value_placeholder(%{"rest_type" => "percentage"}), do: "%"
  defp value_placeholder(_), do: "shares"

  # -- Saving ------------------------------------------------------------------------

  defp attrs(%{f: f, data: data, split_error: split_error} = assigns) do
    private? = f["private"] == "true"

    with {:amount, {:ok, cents}} <- {:amount, Format.parse_money(f["amount"])},
         {:split, nil, {:ok, split}} <- {:split, split_error, build_split(assigns)} do
      {:ok,
       %{
         description: f["description"],
         amount_cents: cents,
         date: f["date"],
         category_id: blank_to_nil(f["category_id"]),
         paid_by: if(private?, do: data.me, else: f["paid_by"]),
         visibility: if(private?, do: "private", else: "shared"),
         split: split
       }}
    else
      {:amount, _} -> {:error, {:field, :amount_cents, "type an amount, like 12.50"}}
      {:split, _, _} -> {:error, :split}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp errors(changeset) do
    changeset.errors
    |> Enum.group_by(&elem(&1, 0), fn {_, e} -> TabWeb.CoreComponents.translate_error(e) end)
  end

  defp split_error(changeset, socket) do
    case Keyword.get_values(changeset.errors, :split) do
      [{msg, _} | _] -> msg
      [] -> socket.assigns.split_error
    end
  end

  defp error_message(:forbidden),
    do: "You can't change this expense. Its creator or an admin can."

  defp error_message(:not_found), do: "That expense is gone or you can't change it."
  defp error_message({:invalid, message}), do: "That didn't save: #{message}."
  defp error_message(_), do: "That didn't save. Try again."

  defp back_path(data, nil), do: ~p"/groups/#{data.group}"
  defp back_path(data, expense), do: ~p"/groups/#{data.group}/expenses/#{expense}"
end
