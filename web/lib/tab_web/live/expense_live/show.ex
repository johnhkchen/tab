defmodule TabWeb.ExpenseLive.Show do
  @moduledoc "One expense: what it was, everyone's share, and every change made to it."
  use TabWeb, :live_view

  alias Tab.Ledger
  alias TabWeb.GroupData

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/groups/#{@data.group}"}>{@data.group.name}</.back>
      <.header>
        {@expense.description}
        <:subtitle>
          <.money cents={@expense.amount_cents} class="font-semibold text-ink" />
          · {GroupData.name_user(@data, @expense.paid_by)} paid on {format_date(@expense.date)}
        </:subtitle>
        <:actions :if={@can_edit}>
          <.button variant="soft" navigate={~p"/groups/#{@data.group}/expenses/#{@expense}/edit"}>
            Edit
          </.button>
          <.button
            variant="warn"
            phx-click="delete"
            data-confirm="Take this out of the balances? It stays in the history."
          >
            Delete
          </.button>
        </:actions>
      </.header>

      <div :if={@expense.visibility == "private"} class="clay-well p-4">
        Only you can see this. It isn't in the group's balances.
      </div>
      <div :if={@expense.deleted_at} class="clay-well p-4">
        Deleted: it no longer counts toward anyone's balance.
      </div>

      <.card title="Shares" id="shares">
        <ul class="divide-y divide-line">
          <li :for={s <- @shares} class="flex justify-between gap-4 py-2">
            <span>
              {GroupData.name(@data, GroupData.share_party(s))}
              <span :if={wait = @waits[GroupData.share_party(s)]} class="block text-sm text-ink-soft">
                {wait_label(wait)}
              </span>
            </span>
            <.money cents={s.amount_cents} />
          </li>
        </ul>
        <.list>
          <:item title="Split">{split_label(@expense.split)}</:item>
          <:item title="Category">
            {GroupData.category_name(@data, @expense.category_id) || "None"}
          </:item>
          <:item :if={@expense.via == "claude"} title="Added">From Claude</:item>
          <:item :if={@expense.edited_at} title="Last edited">
            {format_date(@expense.edited_at)}
          </:item>
        </.list>
      </.card>

      <.card :if={@references != []} title="What arrived about this bill" id="references">
        <TabWeb.Documents.list documents={@references} id="reference-list" />
        <p class="mt-2 text-xs text-ink-soft">
          Tab doesn't keep the originals. Whoever forwarded them can find each one with its search line.
        </p>
      </.card>

      <.card title="History" id="history">
        <ul class="divide-y divide-line">
          <li :for={entry <- @history} class="py-2">
            <span class="font-semibold">{actor(@data, entry.actor_id)}</span>
            {describe(entry)}
            <span class="block text-sm text-ink-soft">{format_date(entry.at)}</span>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"group_id" => group_id, "id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    data = GroupData.load!(scope, group_id)

    expense =
      with {:ok, _} <- Ecto.UUID.cast(id),
           {:ok, %{group_id: ^group_id} = e} <- Ledger.get_expense(scope, id) do
        e
      else
        _ -> raise GroupData.NotFound
      end

    {:ok, history} = Ledger.history(scope, data.group.id, row_id: expense.id)
    {:ok, references} = Tab.Inbox.references(scope, expense.id)

    # How long each share has waited, or waited, to be paid back.
    waits =
      if expense.deleted_at || expense.visibility == "private" do
        %{}
      else
        {:ok, walk} = Ledger.float(scope, data.group.id)
        for {{id, party}, wait} <- walk.shares, id == expense.id, into: %{}, do: {party, wait}
      end

    can_edit =
      !data.archived? and is_nil(expense.deleted_at) and
        (expense.created_by == data.me or (data.admin? and expense.visibility == "shared"))

    {:ok,
     assign(socket,
       data: data,
       expense: expense,
       shares: Enum.sort_by(expense.shares, &GroupData.name(data, GroupData.share_party(&1))),
       history: history,
       references: references,
       waits: waits,
       can_edit: can_edit,
       page_title: expense.description
     )}
  end

  @impl true
  def handle_event("delete", _, socket) do
    case Ledger.delete_expense(socket.assigns.current_scope, socket.assigns.expense.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted. It's out of the balances and still in the history.")
         |> push_navigate(to: ~p"/groups/#{socket.assigns.data.group}")}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "You can't delete this one. Its creator or an admin can.")}
    end
  end

  defp wait_label(%{open_cents: 0, days: 0}), do: "paid back the same day"
  defp wait_label(%{open_cents: 0, days: 1}), do: "paid back after 1 day"
  defp wait_label(%{open_cents: 0, days: d}), do: "paid back after #{d} days"
  defp wait_label(%{days: 1}), do: "waiting 1 day so far"
  defp wait_label(%{days: d}), do: "waiting #{d} days so far"

  defp actor(_data, nil), do: "Tab"
  defp actor(data, id), do: GroupData.name_user(data, id)

  defp describe(%{action: "insert"}), do: "added it."
  defp describe(%{action: "soft_delete"}), do: "deleted it."

  defp describe(%{action: "update", before: b, after: a}) do
    changed =
      [
        {"amount_cents", "the amount"},
        {"description", "the description"},
        {"date", "the date"},
        {"paid_by", "who paid"},
        {"split", "the split"},
        {"category_id", "the category"},
        {"visibility", "who can see it"}
      ]
      |> Enum.filter(fn {k, _} -> b[k] != a[k] end)
      |> Enum.map(&elem(&1, 1))

    case changed do
      [] -> "updated it."
      list -> "changed " <> Enum.join(list, ", ") <> "."
    end
  end

  defp split_label(%{"type" => "equal"}), do: "Evenly"
  defp split_label(%{"type" => "exact"}), do: "By exact amounts"
  defp split_label(%{"type" => "percentage"}), do: "By percentages"
  defp split_label(%{"type" => "shares"}), do: "By shares"
  defp split_label(%{"type" => "tiered"}), do: "Fixed amounts first, then the rest"
  defp split_label(_), do: "Custom"
end
