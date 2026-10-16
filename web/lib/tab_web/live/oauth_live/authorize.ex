defmodule TabWeb.OAuthLive.Authorize do
  @moduledoc """
  The consent page (docs/specification.md, "Endpoints"): an app such as
  Claude asks to use Tab as the signed-in person. Approving makes a
  connection and sends the browser back to the app with a code.
  """
  use TabWeb, :live_view

  alias Tab.OAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @request do %>
        <.header>
          Connect {@request.client.name}
          <:subtitle>
            {@request.client.name} wants to use Tab as you, {@current_scope.user.email}.
          </:subtitle>
        </.header>

        <.card id="consent">
          <p class="text-sm text-ink-soft" id="from">From {@from}</p>
          <.form for={%{}} as={:consent} id="consent-form" phx-submit="approve" class="mt-3 space-y-3">
            <p>It can see your groups, balances, expenses, and bills to check.</p>
            <label :if={"tab:write" in @request.scopes} class="flex items-start gap-2">
              <input type="hidden" name="write" value="false" />
              <input type="checkbox" name="write" value="true" checked class="mt-1" />
              <span>Let it add expenses and record payments, marked "Added from Claude".</span>
            </label>
            <p class="text-sm text-ink-soft">
              It can't edit or delete anything, and it can't confirm payments. You can disconnect it
              any time on your <.link navigate={~p"/profile"} class="underline">You page</.link>.
            </p>
            <div class="flex flex-wrap gap-2">
              <.button type="submit" id="approve">Connect</.button>
              <.button type="button" variant="soft" phx-click="deny" id="deny">
                Don't connect
              </.button>
            </div>
          </.form>
        </.card>
      <% else %>
        <.header>
          This link can't connect an app
          <:subtitle>{@problem}</:subtitle>
        </.header>
        <p class="text-ink-soft">
          Try connecting again from the app. If it keeps happening, the app may not work with Tab yet.
        </p>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, page_title: "Connect an app")

    cond do
      not OAuth.enabled?() ->
        {:ok, assign(socket, request: nil, problem: "This copy of Tab doesn't connect to apps.")}

      true ->
        case OAuth.check_request(params) do
          {:ok, request} ->
            {:ok, assign(socket, request: request, from: from(request))}

          {:error, :no_redirect, message} ->
            {:ok, assign(socket, request: nil, problem: message)}

          {:error, url} ->
            {:ok, redirect(socket, external: url)}
        end
    end
  end

  @impl true
  def handle_event("approve", params, socket) do
    write? = params["write"] == "true"
    url = OAuth.approve(socket.assigns.current_scope, socket.assigns.request, write?)
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("deny", _params, socket) do
    {:noreply, redirect(socket, external: OAuth.deny(socket.assigns.request))}
  end

  # Where the app lives, as the person can check it: the metadata document's
  # host, or "an app on this computer" for a loopback return address.
  defp from(%{client: client, redirect_uri: redirect}) do
    host = URI.parse(redirect).host

    cond do
      client.kind == "cimd" -> URI.parse(client.client_id).host
      host in ["localhost", "127.0.0.1", "::1", "[::1]"] -> "an app on this computer"
      true -> host
    end
  end
end
