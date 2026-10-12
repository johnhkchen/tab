defmodule TabWeb.JoinLive do
  @moduledoc """
  Opening an invite link. Signing in comes first (the router sends you back
  here afterwards); then one button joins. The page can't name the group before
  you join: only its admins can read the invite.
  """
  use TabWeb, :live_view

  alias Tab.Groups

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <%= case @state do %>
          <% :ready -> %>
            <.header>
              You're invited
              <:subtitle>
                Someone added you to a group on Tab, to keep track of who paid for what.
              </:subtitle>
            </.header>
            <.button id="join" class="w-full" phx-click="join" phx-disable-with="Joining…">
              Join the group
            </.button>
          <% :invalid -> %>
            <.header>
              This invite link doesn't work any more
              <:subtitle>
                It's been used, it's past its 7 days, or it was turned off. Ask whoever sent it for a new one.
              </:subtitle>
            </.header>
            <.button variant="soft" navigate={~p"/groups"}>Your groups</.button>
          <% :already -> %>
            <.header>
              You're already in this group
              <:subtitle>The link is still good for someone else.</:subtitle>
            </.header>
            <.button variant="soft" navigate={~p"/groups"}>Your groups</.button>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok, assign(socket, token: token, state: :ready, page_title: "Join")}
  end

  @impl true
  def handle_event("join", _, socket) do
    case Groups.accept_invite(socket.assigns.current_scope, socket.assigns.token) do
      {:ok, group_id} ->
        {:noreply,
         socket
         |> put_flash(:info, "You're in.")
         |> push_navigate(to: ~p"/groups/#{group_id}")}

      {:error, :already_member} ->
        {:noreply, assign(socket, state: :already)}

      {:error, _} ->
        {:noreply, assign(socket, state: :invalid)}
    end
  end
end
