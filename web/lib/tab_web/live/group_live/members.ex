defmodule TabWeb.GroupLive.Members do
  @moduledoc """
  Who's in the group: members, invite links, and counterparties (outside
  parties like a landlord). Admins also rename, archive, and manage people.
  """
  use TabWeb, :live_view

  alias Tab.{Groups, Ledger}
  alias TabWeb.GroupData

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/groups/#{@data.group}"}>{@data.group.name}</.back>
      <.header>People</.header>

      <.card title="Members" id="members">
        <ul class="divide-y divide-line">
          <li
            :for={m <- @data.members}
            id={"member-#{m.user_id}"}
            class="flex flex-wrap items-center justify-between gap-2 py-3"
          >
            <span>
              <span class="font-semibold">{GroupData.name_user(@data, m.user_id)}</span>
              <span :if={m.role == "admin"} class="clay-chip ml-1 px-2 py-0.5 text-xs">Admin</span>
              <span :if={m.profile.payment_methods != []} class="block text-sm text-ink-soft">
                {Enum.map_join(
                  m.profile.payment_methods,
                  " · ",
                  &"#{method_name(&1["kind"])} #{&1["handle"]}"
                )}
              </span>
            </span>
            <span
              :if={@data.admin? && !@data.archived? && m.user_id != @data.me}
              class="flex flex-wrap gap-2 text-sm"
            >
              <button
                phx-click="role"
                phx-value-user={m.user_id}
                phx-value-role={if m.role == "admin", do: "member", else: "admin"}
                class="clay-chip px-3 py-1"
              >
                {if m.role == "admin", do: "Make a member", else: "Make an admin"}
              </button>
              <button
                phx-click="remove"
                phx-value-user={m.user_id}
                data-confirm="Remove them from the group? What they owe or are owed stays in the balances."
                class="px-2 py-1 text-warn underline"
              >
                Remove
              </button>
            </span>
          </li>
        </ul>
      </.card>

      <.card :if={@data.admin? && !@data.archived?} title="Invite someone" id="invites">
        <p class="mb-3 text-ink-soft">
          Each link works once, for 7 days. Send it however you like: text, email, a note on the fridge.
        </p>
        <div :if={@new_link} class="mb-4 space-y-2">
          <input
            id="invite-link"
            readonly
            value={@new_link}
            class="tab-field"
            phx-click={JS.dispatch("tab:select")}
          />
          <.button variant="soft" phx-click={JS.dispatch("tab:copy", to: "#invite-link")}>Copy link</.button>
          <p class="text-sm text-ink-soft">
            You'll see this link only once. Make another any time.
          </p>
        </div>
        <.button phx-click="invite">Make an invite link</.button>
        <ul :if={@invites != []} class="mt-4 divide-y divide-line text-sm">
          <li :for={i <- @invites} class="flex items-center justify-between gap-2 py-2">
            <span>Unused link, good until {format_date(i.expires_at)}</span>
            <button phx-click="revoke" phx-value-id={i.id} class="text-warn underline">Turn off</button>
          </li>
        </ul>
      </.card>

      <.card title="Outside the group" id="counterparties">
        <p class="mb-3 text-ink-soft">
          People and places you split with or pay who don't use Tab: a landlord, a utility, the neighbors.
          They can't sign in or see anything.
        </p>
        <ul :if={@data.counterparties != []} class="mb-4 divide-y divide-line">
          <li :for={c <- @data.counterparties} class="flex items-center justify-between gap-2 py-2">
            <span>{c.name}</span>
            <button
              :if={!@data.archived?}
              phx-click="archive_counterparty"
              phx-value-id={c.id}
              class="text-sm text-ink-soft underline"
            >
              Remove
            </button>
          </li>
        </ul>
        <form
          :if={!@data.archived?}
          id="counterparty_form"
          phx-submit="add_counterparty"
          class="flex flex-wrap items-end gap-2"
        >
          <div class="min-w-48 flex-1">
            <.input
              name="name"
              id="counterparty_name"
              label="Name"
              placeholder="Landlord"
              value=""
              required
            />
          </div>
          <.button variant="soft" class="mb-3">Add</.button>
        </form>
      </.card>

      <.card :if={@data.admin? && !@data.archived?} title="The group" id="group-settings">
        <form id="rename_form" phx-submit="rename" class="flex flex-wrap items-end gap-2">
          <div class="min-w-48 flex-1">
            <.input name="name" id="group_name" label="Name" value={@data.group.name} required />
          </div>
          <.button variant="soft" class="mb-3">Rename</.button>
        </form>
        <div class="mt-2 border-t border-line pt-4">
          <p class="mb-3 text-ink-soft">
            Archiving keeps everything readable but stops all changes. You can undo it.
          </p>
          <p :if={@balances != []} id="archive-warning" class="mb-3 text-warn">
            Some people still owe money here. Archive anyway, and those balances stay as they are.
          </p>
          <.button
            variant="soft"
            phx-click="archive"
            data-confirm="Archive this group? Nothing in it can change until it's unarchived."
          >
            Archive the group
          </.button>
        </div>
      </.card>

      <div :if={!@data.archived?}>
        <.button
          variant="soft"
          phx-click="leave"
          data-confirm="Leave this group? You'll lose access to it."
        >
          Leave the group
        </.button>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"group_id" => group_id}, _session, socket) do
    data = GroupData.load!(socket.assigns.current_scope, group_id)
    {:ok, socket |> assign(data: data, new_link: nil, page_title: "People") |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    data = GroupData.load!(scope, socket.assigns.data.group.id)

    invites =
      if data.admin? do
        {:ok, invites} = Groups.list_invites(scope, data.group.id)
        invites
      else
        []
      end

    {:ok, balances} = Ledger.balances(scope, data.group.id)
    assign(socket, data: data, invites: invites, balances: balances)
  end

  @impl true
  def handle_event("invite", _, socket) do
    case Groups.create_invite(socket.assigns.current_scope, socket.assigns.data.group.id) do
      {:ok, {token, _}} ->
        {:noreply, socket |> assign(new_link: url(~p"/join/#{token}")) |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only admins can make invite links.")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Groups.revoke_invite(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> assign(new_link: nil)
     |> load()
     |> put_flash(:info, "That link won't work any more.")}
  end

  def handle_event("role", %{"user" => user, "role" => role}, socket)
      when role in ~w(admin member) do
    result =
      Groups.set_role(socket.assigns.current_scope, socket.assigns.data.group.id, user, role)

    {:noreply, socket |> load() |> flash_result(result, "Done.")}
  end

  def handle_event("remove", %{"user" => user}, socket) do
    result =
      Groups.remove_member(socket.assigns.current_scope, socket.assigns.data.group.id, user)

    {:noreply, socket |> load() |> flash_result(result, "Removed.")}
  end

  def handle_event("add_counterparty", %{"name" => name}, socket) do
    case Groups.create_counterparty(socket.assigns.current_scope, socket.assigns.data.group.id, %{
           name: name
         }) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Added #{String.trim(name)}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Give them a name, up to 120 characters.")}
    end
  end

  def handle_event("archive_counterparty", %{"id" => id}, socket) do
    result = Groups.archive_counterparty(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> load()
     |> flash_result(result, "Removed. Past expenses with them stay as they were.")}
  end

  def handle_event("rename", %{"name" => name}, socket) do
    case Groups.rename_group(socket.assigns.current_scope, socket.assigns.data.group.id, name) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Renamed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Give the group a name, up to 120 characters.")}
    end
  end

  def handle_event("archive", _, socket) do
    {:ok, _} = Groups.archive_group(socket.assigns.current_scope, socket.assigns.data.group.id)

    {:noreply,
     socket
     |> put_flash(:info, "Archived. Unarchive it from the group page any time.")
     |> push_navigate(to: ~p"/groups/#{socket.assigns.data.group}")}
  end

  def handle_event("leave", _, socket) do
    case Groups.leave_group(socket.assigns.current_scope, socket.assigns.data.group.id) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "You've left the group.") |> push_navigate(to: ~p"/groups")}

      {:error, :unsettled} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Settle up first: you can leave once you're even with everyone, and nothing's waiting on you."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't leave the group.")}
    end
  end

  defp flash_result(socket, {:ok, _}, message), do: put_flash(socket, :info, message)

  defp flash_result(socket, {:error, _}, _),
    do: put_flash(socket, :error, "That didn't work. Only admins can change people.")
end
