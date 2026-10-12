defmodule TabWeb.GroupLive.Settle do
  @moduledoc """
  Settling up: the payments that would make everyone even, a form to record
  one, and payments still waiting for the person paid to say they arrived.
  """
  use TabWeb, :live_view

  alias Tab.Ledger
  alias TabWeb.{Format, GroupData}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/groups/#{@data.group}"}>{@data.group.name}</.back>
      <.header>
        Settle up
        <:subtitle>Tab never moves money. Pay however you like, then record it here.</:subtitle>
      </.header>

      <.card title="To make everyone even" id="suggestions">
        <p :if={@suggestions == []} class="text-ink-soft">Everyone's even. Nothing to pay.</p>
        <ul class="divide-y divide-line">
          <li :for={s <- @suggestions} class="flex flex-wrap items-center justify-between gap-3 py-3">
            <span>
              <strong>{GroupData.name(@data, s.from)}</strong>
              {if s.from == {:user, @data.me}, do: "pay", else: "pays"}
              <strong>{GroupData.name_mid(@data, s.to)}</strong>
              <.money cents={s.amount_cents} class="font-semibold" />
            </span>
            <.button
              :if={!@data.archived?}
              variant="soft"
              phx-click="prefill"
              phx-value-from={GroupData.party_key(s.from)}
              phx-value-to={GroupData.party_key(s.to)}
              phx-value-amount={s.amount_cents}
            >
              Record this
            </.button>
          </li>
        </ul>
        <p :if={length(@suggestions) > 1} class="mt-3 text-sm text-ink-soft">
          These may differ from who owes whom directly: they're the fewest payments that even everyone out.
        </p>
      </.card>

      <.card :if={!@data.archived?} title="Record a payment" id="record">
        <form id="payment_form" phx-change="change" phx-submit="record">
          <div class="grid grid-cols-1 gap-x-4 sm:grid-cols-2">
            <.input
              type="select"
              name="payment[from]"
              id="payment_from"
              label="Who paid"
              options={GroupData.party_options(@data)}
              value={@p["from"]}
            />
            <.input
              type="select"
              name="payment[to]"
              id="payment_to"
              label="Who got it"
              options={GroupData.party_options(@data)}
              value={@p["to"]}
            />
            <.input
              name="payment[amount]"
              id="payment_amount"
              label="How much"
              inputmode="decimal"
              value={@p["amount"]}
              errors={@errors[:amount_cents] || []}
              required
            />
            <.input
              type="date"
              name="payment[date]"
              id="payment_date"
              label="When"
              value={@p["date"]}
              required
            />
            <.input
              type="select"
              name="payment[method]"
              id="payment_method"
              label="How"
              options={method_options()}
              value={@p["method"]}
            />
            <.input
              name="payment[reference]"
              id="payment_reference"
              label="Note (optional)"
              placeholder="Venmo note, check number…"
              value={@p["reference"]}
            />
            <.input
              type="select"
              name="payment[category_id]"
              id="payment_category"
              label="For a category (optional)"
              prompt="Just the overall balance"
              options={Enum.map(@data.categories, &{&1.name, &1.id})}
              value={@p["category_id"]}
            />
          </div>
          <p :if={hint = pay_hint(@data, @p["to"])} class="mb-3 text-sm text-ink-soft">{hint}</p>
          <.error :for={msg <- @errors[:base] || []}>{msg}</.error>
          <.button phx-disable-with="Recording…">Record payment</.button>
        </form>
      </.card>

      <.card :if={@pending != []} title="Waiting to be confirmed" id="pending">
        <ul class="divide-y divide-line">
          <li
            :for={p <- @pending}
            id={"pending-#{p.id}"}
            class="flex flex-wrap items-center justify-between gap-3 py-3"
          >
            <span>
              {GroupData.name(@data, GroupData.from_party(p))} → {GroupData.name(
                @data,
                GroupData.to_party(p)
              )}
              <.money cents={p.amount_cents} class="font-semibold" />
              <span class="block text-sm text-ink-soft">
                {method_name(p.method)} · {format_date(p.date)}{if p.reference,
                  do: " · #{p.reference}"}
              </span>
            </span>
            <span :if={p.to_user_id == @data.me && !@data.archived?} class="flex gap-2">
              <.button phx-click="confirm" phx-value-id={p.id}>Yes, got it</.button>
              <.button variant="soft" phx-click="decline" phx-value-id={p.id}>No</.button>
            </span>
            <span :if={p.to_user_id != @data.me} class="text-sm text-ink-soft">
              Waiting for {GroupData.name(@data, GroupData.to_party(p))}
            </span>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"group_id" => group_id}, _session, socket) do
    data = GroupData.load!(socket.assigns.current_scope, group_id)

    {:ok,
     socket
     |> assign(data: data, errors: %{}, page_title: "Settle up")
     |> assign(p: blank(data))
     |> load()}
  end

  defp blank(data) do
    others = Enum.reject(GroupData.party_options(data), &(elem(&1, 1) == "user:" <> data.me))

    %{
      "from" => "user:" <> data.me,
      "to" => first_key(others, "user:" <> data.me),
      "amount" => "",
      "date" => Date.to_iso8601(Date.utc_today()),
      "method" => "venmo",
      "reference" => "",
      "category_id" => ""
    }
  end

  defp first_key([{_, key} | _], _default), do: key
  defp first_key([], default), do: default

  defp load(socket) do
    scope = socket.assigns.current_scope
    group_id = socket.assigns.data.group.id
    {:ok, suggestions} = Ledger.settle_up(scope, group_id)
    {:ok, payments} = Ledger.list_payments(scope, group_id)

    assign(socket,
      suggestions: suggestions,
      pending: Enum.filter(payments, &(&1.status == "pending"))
    )
  end

  @impl true
  def handle_event("prefill", %{"from" => from, "to" => to, "amount" => cents}, socket) do
    p = %{
      socket.assigns.p
      | "from" => from,
        "to" => to,
        "amount" => Format.amount_input(String.to_integer(cents))
    }

    {:noreply, assign(socket, p: p, errors: %{})}
  end

  def handle_event("change", %{"payment" => p}, socket) do
    {:noreply, assign(socket, p: Map.merge(socket.assigns.p, p))}
  end

  def handle_event("record", %{"payment" => p}, socket) do
    p = Map.merge(socket.assigns.p, p)
    socket = assign(socket, p: p)

    with {:ok, cents} <- amount(p["amount"]),
         {:ok, payment} <-
           Ledger.record_payment(
             socket.assigns.current_scope,
             socket.assigns.data.group.id,
             attrs(p, cents)
           ) do
      message =
        case payment.status do
          "pending" ->
            "Recorded. It counts once #{GroupData.name_user(socket.assigns.data, payment.to_user_id)} confirms it arrived."

          _ ->
            "Recorded."
        end

      {:noreply,
       socket
       |> assign(p: blank(socket.assigns.data), errors: %{})
       |> load()
       |> put_flash(:info, message)}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket,
           errors: %{
             base: Enum.map(cs.errors, fn {_, e} -> TabWeb.CoreComponents.translate_error(e) end)
           }
         )}

      {:error, :amount} ->
        {:noreply, assign(socket, errors: %{amount_cents: ["type an amount, like 25.00"]})}

      {:error, _} ->
        {:noreply,
         assign(socket,
           errors: %{base: ["That payment couldn't be recorded. Check who paid whom."]}
         )}
    end
  end

  def handle_event("confirm", %{"id" => id}, socket) do
    decide(socket, Ledger.confirm_payment(socket.assigns.current_scope, id), "Marked as arrived.")
  end

  def handle_event("decline", %{"id" => id}, socket) do
    decide(
      socket,
      Ledger.decline_payment(socket.assigns.current_scope, id),
      "Marked as not arrived. It won't count."
    )
  end

  defp decide(socket, {:ok, _}, message),
    do: {:noreply, socket |> load() |> put_flash(:info, message)}

  defp decide(socket, {:error, _}, _),
    do:
      {:noreply, socket |> load() |> put_flash(:error, "That payment can't be changed any more.")}

  defp amount(text) do
    case Format.parse_money(text || "") do
      {:ok, cents} when cents > 0 -> {:ok, cents}
      _ -> {:error, :amount}
    end
  end

  defp attrs(p, cents) do
    {from_user, from_cp} = split_party(p["from"])
    {to_user, to_cp} = split_party(p["to"])

    %{
      from_user_id: from_user,
      from_counterparty_id: from_cp,
      to_user_id: to_user,
      to_counterparty_id: to_cp,
      amount_cents: cents,
      date: p["date"],
      method: p["method"],
      reference: if(p["reference"] in [nil, ""], do: nil, else: p["reference"]),
      category_id: if(p["category_id"] in [nil, ""], do: nil, else: p["category_id"])
    }
  end

  defp split_party(key) do
    case GroupData.parse_party(key) do
      {:user, id} -> {id, nil}
      {:counterparty, id} -> {nil, id}
      nil -> {nil, nil}
    end
  end

  defp pay_hint(data, "user:" <> id) do
    if id != data.me do
      case Enum.find_value(data.members, [], &(&1.user_id == id && &1.profile.payment_methods)) do
        [] ->
          nil

        methods ->
          "#{GroupData.name_user(data, id)} takes " <>
            Enum.map_join(methods, ", ", &"#{method_name(&1["kind"])} #{&1["handle"]}")
      end
    end
  end

  defp pay_hint(_, _), do: nil
end
