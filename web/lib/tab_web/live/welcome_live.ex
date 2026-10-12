defmodule TabWeb.WelcomeLive do
  @moduledoc "After the first sign-in: pick the name group-mates will see, then carry on."
  use TabWeb, :live_view

  alias Tab.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <.header>
          What should people call you?
          <:subtitle>This is the name your group-mates see next to what you paid and owe.</:subtitle>
        </.header>

        <.form for={@form} id="welcome_form" phx-submit="save" class="clay-surface p-5">
          <.input field={@form[:display_name]} label="Your name" required phx-mounted={JS.focus()} />
          <.button class="w-full" phx-disable-with="Saving…">Continue</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    profile = Accounts.get_profile(socket.assigns.current_scope)

    {:ok,
     assign(socket,
       form: to_form(Accounts.change_profile(profile)),
       next: safe_next(params["next"]),
       page_title: "Welcome"
     )}
  end

  @impl true
  def handle_event("save", %{"profile" => attrs}, socket) do
    case Accounts.update_profile(socket.assigns.current_scope, Map.take(attrs, ["display_name"])) do
      {:ok, _} -> {:noreply, push_navigate(socket, to: socket.assigns.next)}
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # Only paths on this site; never `//elsewhere.example`.
  defp safe_next("/" <> rest = path) when binary_part(rest, 0, 0) == "" do
    if String.starts_with?(rest, ["/", "\\\\"]), do: ~p"/groups", else: path
  end

  defp safe_next(_), do: ~p"/groups"
end
