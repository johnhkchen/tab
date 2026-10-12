defmodule TabWeb.Layouts do
  @moduledoc """
  The page frame (`app/1`), flash messages, and the root HTML in
  `layouts/root.html.heex`.
  """
  use TabWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The frame around every page: the name, a short menu, and the page itself in
  one readable column that fits a phone.

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :wide, :boolean, default: false, doc: "use a wider column"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="mx-auto flex max-w-3xl flex-wrap items-center justify-between gap-3 px-4 pt-5 sm:px-6">
      <.link
        navigate={if @current_scope, do: ~p"/groups", else: ~p"/"}
        class="font-display text-2xl font-semibold text-ink"
      >
        Tab
      </.link>
      <nav class="flex flex-wrap items-center gap-2 text-sm">
        <%= if @current_scope do %>
          <.link navigate={~p"/groups"} class="clay-chip px-3 py-1.5">Groups</.link>
          <.link navigate={~p"/profile"} class="clay-chip px-3 py-1.5">You</.link>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="px-2 py-1.5 text-ink-soft hover:text-ink"
          >
            Sign out
          </.link>
        <% else %>
          <.link navigate={~p"/users/log-in"} class="clay-chip px-3 py-1.5">Sign in</.link>
        <% end %>
      </nav>
    </header>

    <main class={["mx-auto px-4 pt-8 pb-16 sm:px-6", if(@wide, do: "max-w-3xl", else: "max-w-2xl")]}>
      <div class="space-y-6">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Lost the connection")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Trying again…")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong on our side")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Trying again…")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
