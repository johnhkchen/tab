defmodule TabWeb.UserLive.Login do
  @moduledoc """
  Sign in, and sign up: one email field. A new email gets an account made on
  the spot, so the reply is the same whether or not the email was known.
  """
  use TabWeb, :live_view

  alias Tab.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <.header>
          {if @current_scope, do: "Confirm it's you", else: "Sign in"}
          <:subtitle>
            <%= if @current_scope do %>
              Changing your email or password needs a fresh sign-in.
            <% else %>
              We'll email you a link. New here? The same link makes your account.
            <% end %>
          </:subtitle>
        </.header>

        <div :if={dev_mailbox?()} class="clay-well p-4 text-sm">
          Running locally: emails land in <.link href="/dev/mailbox" class="underline">the dev mailbox</.link>.
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
          class="clay-surface p-5"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="w-full" phx-disable-with="Sending…">Email me a link</.button>
        </.form>

        <details class="clay-surface p-5" open={@password_open}>
          <summary class="cursor-pointer font-semibold">Use a password instead</summary>
          <p class="mt-2 text-sm text-ink-soft">
            Only if you've set one under You → Email and password.
          </p>
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
            class="mt-4"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button class="w-full" name={@form[:remember_me].name} value="true">
              Sign in and stay signed in
            </.button>
            <.button variant="soft" class="mt-2 w-full">Sign in just this once</.button>
          </.form>
        </details>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")
    password_open = Phoenix.Flash.get(socket.assigns.flash, :email) != nil

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       password_open: password_open,
       page_title: "Sign in"
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    full? = Tab.Billing.signups_full?()

    case user_for(email, full?) do
      {:ok, user} -> Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
      :error -> :ok
    end

    # The same words whether or not the address has an account, so the page
    # never says who uses Tab.
    message =
      if full?,
        do:
          "Check your email for a link to sign in. If you're new: Tab has all the new accounts it can take today, so try again tomorrow.",
        else: "Check your email for a link to sign in. It works for 15 minutes."

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp user_for(email, full?) do
    case Accounts.get_user_by_email(email) do
      nil when full? ->
        :error

      nil ->
        case Accounts.register_user(%{email: email}) do
          {:ok, user} -> {:ok, user}
          {:error, _} -> :error
        end

      user ->
        {:ok, user}
    end
  end

  defp dev_mailbox? do
    Application.get_env(:tab, Tab.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
