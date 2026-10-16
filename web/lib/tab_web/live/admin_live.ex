defmodule TabWeb.AdminLive do
  @moduledoc """
  The operator's page on Hosted Tab (docs/specification.md, "The admin
  page"): requests for more trial time, with Grant and Decline, and counts.
  Only for addresses in `TAB_ADMIN_EMAILS`; everyone else gets 404. It never
  shows a group, an expense, a bill, or anyone's ledger.
  """
  use TabWeb, :live_view

  alias Tab.Billing

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Admin
        <:subtitle>Hosted Tab, counted. No one's ledger is shown here.</:subtitle>
      </.header>

      <.card title="Accounts" id="counts">
        <.list>
          <:item title="Accounts">{@stats.accounts}</:item>
          <:item title="On the trial">{@stats.trials}</:item>
          <:item title="Paid Plus">{@stats.paid_plus}</:item>
          <:item title="Hosted free">{@stats.free}</:item>
          <:item title="Bills read this month">
            {@stats.reads_this_month} (about {TabWeb.Format.money(@stats.read_cost_estimate_cents)})
          </:item>
          <:item title="Forwarded emails today">{@stats.mail_today} of Resend's free 100</:item>
        </.list>
      </.card>

      <.card title="Asking for more time" id="requests">
        <p :if={@requests == []} class="text-ink-soft" id="no-requests">Nobody's waiting.</p>
        <ul class="divide-y divide-line">
          <li :for={%{request: r, email: email} <- @requests} id={"request-#{r.id}"} class="py-3">
            <span class="block text-sm text-ink-soft">
              {email} · {format_date(r.inserted_at)} · {if r.may_quote,
                do: "may quote",
                else: "don't quote"}
            </span>
            <span class="block text-sm font-semibold">{r.question}</span>
            <span class="block whitespace-pre-line">{r.answer}</span>
            <div class="mt-2 flex flex-wrap gap-2">
              <.button phx-click="grant" phx-value-id={r.id} id={"grant-#{r.id}"}>
                Grant 6 months
              </.button>
              <.button variant="soft" phx-click="decline" phx-value-id={r.id} id={"decline-#{r.id}"}>
                Decline
              </.button>
            </div>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Billing.admin?(socket.assigns.current_scope) do
      {:ok, socket |> assign(page_title: "Admin") |> load()}
    else
      raise TabWeb.GroupData.NotFound
    end
  end

  defp load(socket),
    do: assign(socket, stats: Billing.stats(), requests: Billing.waiting_requests())

  @impl true
  def handle_event(event, %{"id" => id}, socket) when event in ~w(grant decline) do
    # Checked again on every action, not just on opening the page.
    if Billing.admin?(socket.assigns.current_scope) do
      result = if event == "grant", do: Billing.grant(id), else: Billing.decline(id)

      message =
        case result do
          {:ok, "granted"} -> "Granted. They'll get an email."
          {:ok, "declined"} -> "Declined."
          _ -> "That request was already decided."
        end

      {:noreply, socket |> put_flash(:info, message) |> load()}
    else
      {:noreply, socket}
    end
  end
end
