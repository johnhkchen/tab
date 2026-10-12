defmodule TabWeb.UserLive.Confirmation do
  use TabWeb, :live_view

  alias Tab.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <.header>
          {if @user.confirmed_at, do: "Welcome back", else: "Welcome to Tab"}
          <:subtitle>Signing in as {@user.email}</:subtitle>
        </.header>

        <.form
          for={@form}
          id={if @user.confirmed_at, do: "login_form", else: "confirmation_form"}
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={
            if @user.confirmed_at, do: ~p"/users/log-in", else: ~p"/users/log-in?_action=confirmed"
          }
          phx-trigger-action={@trigger_submit}
          class="clay-surface space-y-2 p-5"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="Signing in…" class="w-full">Sign in</.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Signing in…"
              class="w-full"
            >
              Sign in and stay signed in
            </.button>
            <.button variant="soft" phx-disable-with="Signing in…" class="w-full">
              Sign in just this once
            </.button>
          <% end %>
        </.form>

        <p class="text-sm text-ink-soft">
          Stay signed in on your own phone or computer. On a shared one, choose just this once.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false, page_title: "Sign in"),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         "That sign-in link has expired or was already used. Here's a fresh start."
       )
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
