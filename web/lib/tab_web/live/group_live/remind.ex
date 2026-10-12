defmodule TabWeb.GroupLive.Remind do
  @moduledoc """
  Ask for it: ready-to-send messages for money someone owes you, worded for a
  Venmo note, a text, and an email (`Tab.Reminders`). Tab never sends them.
  You can add a statement link, a page they can open without signing in that
  shows only their own month.
  """
  use TabWeb, :live_view

  alias Tab.{Ledger, Reminders, Statements}
  alias TabWeb.GroupData

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/groups/#{@data.group}"}>{@data.group.name}</.back>
      <.header>
        Ask {@name} for it
        <:subtitle>
          <span :if={@amount > 0}>
            {@name} owes you <.money cents={@amount} class="font-semibold text-ink" />.
          </span>
          <span :if={@amount == 0}>{@name} doesn't owe you anything right now.</span>
          Copy a message and send it from your own app. Tab doesn't send it.
        </:subtitle>
      </.header>

      <div :if={@amount > 0} class="space-y-6">
        <.card :for={{key, label, text} <- drafts(@drafts)} title={label} id={"card-#{key}"}>
          <textarea
            id={"draft-#{key}"}
            readonly
            rows={rows(text)}
            class="tab-field font-body"
            phx-click={JS.dispatch("tab:select")}
          >{text}</textarea>
          <div class="mt-2">
            <.button variant="soft" phx-click={JS.dispatch("tab:copy", to: "#draft-#{key}")}>
              Copy
            </.button>
          </div>
        </.card>
      </div>

      <.card title="Statement link" id="statement">
        <p class="mb-3 text-ink-soft">
          A page {@name} can open without signing in. It shows only their own charges and
          payments for one month, never anyone else's. It works for 30 days, and anyone in
          the group can turn it off.
        </p>
        <form
          :if={!@data.archived?}
          id="link_form"
          phx-submit="make_link"
          class="flex flex-wrap items-end gap-2"
        >
          <div class="min-w-40 flex-1">
            <.input
              name="month"
              id="link_month"
              type="select"
              label="Which month?"
              options={@months}
              value={elem(hd(@months), 1)}
            />
          </div>
          <.button phx-disable-with="Making…" class="mb-2">Add a statement link</.button>
        </form>
        <div :if={@link} class="mt-3 space-y-2">
          <input
            id="statement-link"
            readonly
            value={@link}
            class="tab-field"
            phx-click={JS.dispatch("tab:select")}
          />
          <p class="text-sm text-ink-soft">
            It's in the messages above too. You'll see this link only once.
          </p>
        </div>
        <ul :if={@links != []} class="mt-4 divide-y divide-line text-sm" id="links">
          <li :for={l <- @links} class="flex items-center justify-between gap-2 py-2">
            <span>
              {Calendar.strftime(l.period_start, "%B %Y")} · works until {format_date(l.expires_at)}
            </span>
            <button
              :if={!@data.archived?}
              phx-click="revoke"
              phx-value-id={l.id}
              class="px-2 py-1 text-warn underline"
            >
              Turn off
            </button>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"group_id" => group_id, "party" => key}, _session, socket) do
    scope = socket.assigns.current_scope
    data = GroupData.load!(scope, group_id)

    party =
      case GroupData.parse_party(key) do
        {_, id} = party when is_binary(id) ->
          if Map.has_key?(data.names, party), do: party, else: raise(GroupData.NotFound)

        nil ->
          raise GroupData.NotFound
      end

    if party == {:user, data.me}, do: raise(GroupData.NotFound)

    today = Date.utc_today()

    months =
      for n <- 0..5 do
        d = Date.shift(Date.beginning_of_month(today), month: -n)
        {Calendar.strftime(d, "%B %Y"), Date.to_iso8601(d)}
      end

    {:ok,
     socket
     |> assign(
       data: data,
       party: party,
       name: GroupData.name(data, party),
       months: months,
       link: nil,
       page_title: "Ask for it"
     )
     |> load()}
  end

  defp load(socket) do
    %{current_scope: scope, data: data, party: party} = socket.assigns
    me = {:user, data.me}

    amount =
      Enum.find_value(GroupData.balances(scope, data), 0, fn b ->
        b.debtor == party and b.creditor == me and b.amount_cents
      end)

    {:ok, walk} = Ledger.float(scope, data.group.id)
    {:ok, links} = Statements.list_links(scope, data.group.id, party)
    items = Map.get(walk.open, {party, me}, [])

    socket
    |> assign(amount: amount, links: links, items: items)
    |> draft()
  end

  defp draft(socket) do
    %{data: data, name: name, amount: amount, items: items, link: link} = socket.assigns
    me = Enum.find(data.members, &(&1.user_id == data.me))

    drafts =
      Reminders.drafts(%{
        to: name,
        from: me.profile.display_name,
        group: data.group.name,
        amount_cents: amount,
        items: items,
        methods: me.profile.payment_methods,
        link: link
      })

    assign(socket, drafts: drafts)
  end

  @impl true
  def handle_event("make_link", %{"month" => month}, socket) do
    %{current_scope: scope, data: data, party: party} = socket.assigns

    with {:ok, day} <- Date.from_iso8601(month),
         {:ok, token, _link} <- Statements.create_link(scope, data.group.id, party, day) do
      {:noreply, socket |> assign(link: url(~p"/s/#{token}")) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "That link didn't save. Try again.")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Statements.revoke_link(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Turned off.") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "That link can't be changed.")}
    end
  end

  defp drafts(d) do
    [
      {"venmo", "Venmo note", d.venmo},
      {"text", "Text", d.text},
      {"email", "Email", "Subject: #{d.email.subject}\n\n#{d.email.body}"}
    ]
  end

  # Enough rows to read the whole draft at phone width.
  defp rows(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(div(String.length(&1), 36) + 1))
    |> Enum.sum()
    |> max(2)
    |> min(18)
  end
end
