defmodule TabWeb.GroupLive.Show do
  @moduledoc "A group at a glance: who owes whom, what's waiting on you, and what happened lately."
  use TabWeb, :live_view

  alias Tab.{Groups, Ledger}
  alias TabWeb.GroupData

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/groups"}>Your groups</.back>
      <.header>
        {@data.group.name}
        <:actions>
          <.button :if={!@data.archived?} navigate={~p"/groups/#{@data.group}/expenses/new"}>
            Add expense
          </.button>
          <.button variant="soft" navigate={~p"/groups/#{@data.group}/settle"}>Settle up</.button>
          <.button variant="soft" navigate={~p"/groups/#{@data.group}/members"}>People</.button>
        </:actions>
      </.header>

      <nav class="flex flex-wrap gap-2 text-sm" id="group-nav">
        <.link navigate={~p"/groups/#{@data.group}/bills"} class="clay-chip px-3 py-1">Bills</.link>
        <.link navigate={~p"/groups/#{@data.group}/temporary"} class="clay-chip px-3 py-1">
          Temporary splits
        </.link>
      </nav>

      <div :if={@data.archived?} id="archived" class="clay-well p-4">
        This group is archived: you can read everything, but nothing can change.
        <button :if={@data.admin?} phx-click="unarchive" class="ml-1 font-semibold underline">
          Unarchive it
        </button>
      </div>

      <.card :if={@pending != []} title="Did this arrive?" id="pending">
        <ul class="divide-y divide-line">
          <li
            :for={p <- @pending}
            id={"pending-#{p.id}"}
            class="flex flex-wrap items-center justify-between gap-3 py-3"
          >
            <span>
              {GroupData.name(@data, GroupData.from_party(p))} says they sent you
              <.money cents={p.amount_cents} class="font-semibold" />
              by {method_name(p.method)} on {format_date(p.date)}.
            </span>
            <span :if={!@data.archived?} class="flex gap-2">
              <.button phx-click="confirm" phx-value-id={p.id}>Yes, got it</.button>
              <.button variant="soft" phx-click="decline" phx-value-id={p.id}>No</.button>
            </span>
          </li>
        </ul>
      </.card>

      <.card title="Who owes whom" id="balances">
        <:actions>
          <button
            :if={@category_balances != []}
            phx-click="toggle_categories"
            class="clay-chip px-3 py-1 text-sm"
          >
            {if @by_category, do: "Overall", else: "By category"}
          </button>
        </:actions>
        <p :if={@balances == []} class="text-ink-soft">Everyone's even.</p>

        <ul :if={!@by_category && @balances != []} class="divide-y divide-line">
          <li :for={b <- @balances} class="py-3">
            <div class="flex justify-between gap-4">
              <span>
                <strong>{GroupData.name(@data, b.debtor)}</strong>
                {if b.debtor == {:user, @data.me}, do: "owe", else: "owes"}
                <strong>{GroupData.name_mid(@data, b.creditor)}</strong>
              </span>
              <.money cents={b.amount_cents} class="font-semibold" />
            </div>
            <p :if={b.debtor == {:user, @data.me}} class="mt-1 text-sm text-ink-soft">
              {pay_hint(@data, b.creditor)}
            </p>
            <p :if={b.creditor == {:user, @data.me}} class="mt-1 text-sm">
              <.link
                navigate={~p"/groups/#{@data.group}/remind/#{GroupData.party_key(b.debtor)}"}
                class="underline"
              >
                Ask for it
              </.link>
            </p>
          </li>
        </ul>

        <div :if={@by_category} class="space-y-4">
          <div :for={{category_id, rows} <- Enum.group_by(@category_balances, & &1.category_id)}>
            <h3 class="mb-1 font-semibold">
              {GroupData.category_name(@data, category_id) || "Other"}
            </h3>
            <ul class="divide-y divide-line">
              <li :for={b <- rows} class="flex justify-between gap-4 py-2">
                <span>
                  {GroupData.name(@data, b.debtor)} → {GroupData.name_mid(@data, b.creditor)}
                </span>
                <.money cents={b.amount_cents} />
              </li>
            </ul>
          </div>
          <p class="text-sm text-ink-soft">
            A payment counts here only if whoever recorded it picked the category.
          </p>
        </div>
      </.card>

      <.card :if={@waits != []} title="How long money waits" id="float">
        <p class="mb-2 text-sm text-ink-soft">
          Days between paying for everyone and getting the rest back, on average.
          Days only, no interest.
        </p>
        <ul class="divide-y divide-line">
          <li :for={{party, days} <- @waits} class="flex justify-between gap-4 py-2">
            <span>{GroupData.name(@data, party)}</span>
            <span class="money">{days_label(days)}</span>
          </li>
        </ul>
      </.card>

      <.card title="Lately" id="activity">
        <p :if={@activity == []} class="text-ink-soft">
          Nothing yet. Add the first expense and Tab works out who owes what.
        </p>
        <ul class="divide-y divide-line">
          <li :for={item <- @activity} class="py-3">
            <.activity_item item={item} data={@data} />
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  attr :item, :any, required: true
  attr :data, :any, required: true

  defp activity_item(%{item: {:expense, e}} = assigns) do
    assigns = assign(assigns, :e, e)

    ~H"""
    <.link navigate={~p"/groups/#{@data.group}/expenses/#{@e}"} class="flex justify-between gap-4">
      <span>
        <span class="font-semibold">{@e.description}</span>
        <span :if={@e.visibility == "private"} class="clay-chip ml-1 px-2 py-0.5 text-xs">Only you</span>
        <span :if={@e.edited_at} class="ml-1 text-xs text-ink-soft">edited</span>
        <span class="block text-sm text-ink-soft">
          {GroupData.name_user(@data, @e.paid_by)} paid · {format_date(@e.date)}
        </span>
      </span>
      <.money cents={@e.amount_cents} />
    </.link>
    """
  end

  defp activity_item(%{item: {:payment, p}} = assigns) do
    assigns = assign(assigns, :p, p)

    ~H"""
    <div class="flex justify-between gap-4">
      <span>
        {GroupData.name(@data, GroupData.from_party(@p))} paid {GroupData.name(
          @data,
          GroupData.to_party(@p)
        )}
        <span class="block text-sm text-ink-soft">
          {method_name(@p.method)} · {format_date(@p.date)} · {status_label(@p.status)}
        </span>
      </span>
      <.money cents={@p.amount_cents} class={@p.status in ["pending", "declined"] && "text-ink-soft"} />
    </div>
    """
  end

  @impl true
  def mount(%{"group_id" => group_id}, _session, socket) do
    data = GroupData.load!(socket.assigns.current_scope, group_id)
    {:ok, socket |> assign(data: data, by_category: false, page_title: data.group.name) |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    group_id = socket.assigns.data.group.id
    {:ok, pending} = Ledger.pending_for_me(scope, group_id)
    {:ok, category_balances} = Ledger.category_balances(scope, group_id)
    {:ok, activity} = Ledger.activity(scope, group_id)
    {:ok, walk} = Ledger.float(scope, group_id)

    waits =
      walk.by_creditor
      |> Enum.filter(fn {party, _} -> match?({:user, _}, party) end)
      |> Enum.sort_by(fn {party, _} -> GroupData.name(socket.assigns.data, party) end)

    assign(socket,
      balances: GroupData.balances(scope, socket.assigns.data),
      category_balances: category_balances,
      pending: pending,
      activity: activity,
      waits: waits
    )
  end

  @impl true
  def handle_event("toggle_categories", _, socket) do
    {:noreply, update(socket, :by_category, &(!&1))}
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

  def handle_event("unarchive", _, socket) do
    {:ok, _} = Groups.unarchive_group(socket.assigns.current_scope, socket.assigns.data.group.id)
    data = GroupData.load!(socket.assigns.current_scope, socket.assigns.data.group.id)
    {:noreply, socket |> assign(data: data) |> put_flash(:info, "Unarchived.")}
  end

  defp decide(socket, {:ok, _}, message),
    do: {:noreply, socket |> load() |> put_flash(:info, message)}

  defp decide(socket, {:error, _}, _),
    do:
      {:noreply, socket |> load() |> put_flash(:error, "That payment can't be changed any more.")}

  defp pay_hint(data, {:user, id} = creditor) do
    methods =
      Enum.find_value(data.members, [], fn m -> m.user_id == id && m.profile.payment_methods end)

    case methods do
      [] ->
        "#{GroupData.name(data, creditor)} hasn't added a way to pay them yet."

      methods ->
        "Pay them by " <>
          Enum.map_join(methods, " or ", &"#{method_name(&1["kind"])} #{&1["handle"]}")
    end
  end

  defp pay_hint(_, _), do: nil

  defp days_label(1), do: "1 day"
  defp days_label(n), do: "#{n} days"
end
