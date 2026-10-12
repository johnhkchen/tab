defmodule TabWeb.GroupLive.Index do
  @moduledoc "Your groups, with where you stand in each, and a way to start one."
  use TabWeb, :live_view

  alias Tab.{Groups, Ledger}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Your groups
        <:subtitle>A group is anyone you share costs with: a house, a trip, a couple.</:subtitle>
      </.header>

      <.card :if={@waiting != []} title="Waiting on you" id="waiting">
        <p class="text-ink-soft">
          {length(@waiting)} {if length(@waiting) == 1, do: "payment needs", else: "payments need"} you to say whether it arrived.
        </p>
        <ul class="mt-3 space-y-1">
          <li :for={g <- @groups_waiting}>
            <.link navigate={~p"/groups/#{g.id}/settle"} class="underline">{g.name}</.link>
          </li>
        </ul>
      </.card>

      <.card :if={@to_check > 0} title="Bills to check" id="to-check">
        <p class="text-ink-soft">
          {if @to_check == 1, do: "A bill you sent is", else: "#{@to_check} bills you sent are"} waiting for you to check.
          <.link navigate={~p"/inbox"} class="underline">Check and save</.link>
        </p>
      </.card>

      <ul id="groups" class="space-y-3">
        <li :for={group <- @groups}>
          <.link
            navigate={~p"/groups/#{group.id}"}
            class="clay-surface flex items-center justify-between gap-4 p-5 hover:-translate-y-px"
          >
            <span>
              <span class="font-display text-xl font-semibold">{group.name}</span>
              <span :if={group.deleted_at} class="clay-chip ml-2 px-2 py-0.5 text-xs">Archived</span>
            </span>
            <.standing cents={Map.get(@nets, group.id, 0)} />
          </.link>
        </li>
      </ul>

      <p :if={@groups == []} class="text-ink-soft">
        No groups yet. Start one below, or open an invite link someone sent you.
      </p>

      <.card title="Start a group">
        <.form for={@form} id="new_group" phx-submit="create" class="flex flex-wrap items-end gap-2">
          <div class="min-w-48 flex-1">
            <.input field={@form[:name]} label="Name" placeholder="Elm Street house" required />
          </div>
          <.button class="mb-3" phx-disable-with="Starting…">Start</.button>
        </.form>
      </.card>
    </Layouts.app>
    """
  end

  attr :cents, :integer, required: true

  def standing(%{cents: 0} = assigns), do: ~H|<span class="text-ink-soft">All even</span>|

  def standing(assigns) do
    ~H"""
    <span class="text-right">
      <span class="block text-sm text-ink-soft">{if @cents > 0, do: "You're owed", else: "You owe"}</span>
      <.money cents={abs(@cents)} class={["font-semibold", @cents > 0 && "text-primary"]} />
    </span>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Your groups") |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    {:ok, groups} = Groups.list_groups(scope)
    {:ok, nets} = Ledger.my_nets(scope)
    {:ok, waiting} = Ledger.pending_for_me(scope)
    waiting_ids = MapSet.new(waiting, & &1.group_id)
    {:ok, to_check} = Tab.Inbox.ready_count(scope)

    assign(socket,
      groups: groups,
      nets: nets,
      waiting: waiting,
      to_check: to_check,
      groups_waiting: Enum.filter(groups, &MapSet.member?(waiting_ids, &1.id)),
      form: to_form(%{"name" => ""}, as: "group")
    )
  end

  @impl true
  def handle_event("create", %{"group" => attrs}, socket) do
    case Groups.create_group(socket.assigns.current_scope, attrs) do
      {:ok, group} ->
        {:noreply, push_navigate(socket, to: ~p"/groups/#{group.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "group"))}
    end
  end
end
