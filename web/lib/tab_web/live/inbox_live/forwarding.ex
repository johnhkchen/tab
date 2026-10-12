defmodule TabWeb.InboxLive.Forwarding do
  @moduledoc """
  Forward bills by email (docs/specification.md, "Forwarding setup"): your
  private address, how to set up a filter in your own mail, and the last few
  emails that arrived. Tab never asks for access to anyone's mailbox.
  """
  use TabWeb, :live_view

  alias Tab.Inbox

  @steps [
    {"gmail", "Gmail",
     [
       "On a computer, open Gmail's settings (the gear), then See all settings.",
       "Open Forwarding and POP/IMAP, choose Add a forwarding address, and paste your Tab address.",
       "Gmail sends Tab a code to check the address. It shows up on this page below; type it into Gmail.",
       "Search for an email from the company that bills you, then open the search options and pick Create filter.",
       "Tick Forward it to, choose your Tab address, and save."
     ]},
    {"outlook", "Outlook.com",
     [
       "Open Settings, then Mail, then Rules, and choose Add new rule.",
       "Name it, and set the condition to From, with the company's email address.",
       "Set the action to Forward to, with your Tab address, and save."
     ]},
    {"icloud", "iCloud Mail",
     [
       "On icloud.com, open Mail, then the settings (the gear), then Rules.",
       "Add a rule: if a message is from the company's address, forward it to your Tab address.",
       "Save it."
     ]},
    {"fastmail", "Fastmail",
     [
       "Open Settings, then Filters & Rules, and add a rule.",
       "Match mail from the company's address.",
       "Choose Send a copy to, with your Tab address, and save."
     ]}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/inbox"}>Bills to check</.back>
      <.header>
        Forward bills by email
        <:subtitle>
          Set up a filter in your email, and each new bill from that company lands here for you to check.
        </:subtitle>
      </.header>

      <.card :if={!@enabled} id="off">
        <p class="text-ink-soft">
          This copy of Tab can't receive email. The person who runs it can turn it on with Resend,
          following the docs under "Run it yourself". Add a photo or a PDF instead.
        </p>
      </.card>

      <.card :if={@enabled} title="Your Tab address" id="address">
        <input
          id="forward-address"
          readonly
          value={@address}
          class="tab-field"
          phx-click={JS.dispatch("tab:select")}
        />
        <div class="mt-2 flex flex-wrap gap-2">
          <.button variant="soft" phx-click={JS.dispatch("tab:copy", to: "#forward-address")}>Copy</.button>
          <.button
            variant="soft"
            phx-click="new_address"
            data-confirm="Make a new address? Mail sent to this one stops arriving, so update your filters."
          >
            Make a new one
          </.button>
        </div>
        <p class="mt-3 text-sm text-ink-soft">
          Keep it to yourself: anyone who mails it adds to your bills to check. Tab sees what you forward and nothing else.
        </p>
      </.card>

      <.card :for={{key, name, steps} <- @steps} :if={@enabled} id={"steps-#{key}"}>
        <details>
          <summary class="cursor-pointer text-lg font-semibold">In {name}</summary>
          <ol class="mt-3 list-decimal space-y-1 pl-5">
            <li :for={step <- steps}>{step}</li>
          </ol>
        </details>
      </.card>

      <.card :if={@enabled} title="Recent email" id="recent">
        <p :if={@mail == []} class="text-ink-soft">Nothing here. Forward a bill to try it.</p>
        <ul class="divide-y divide-line text-sm">
          <li :for={m <- @mail} class="py-2">
            <span class="block">{m.subject || "(no subject)"}</span>
            <span class="block text-ink-soft">
              {m.from_address} · {format_date(m.received_at)} · {mail_status(m)}
            </span>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Forward bills", steps: @steps) |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    if Inbox.mail_enabled?() do
      {:ok, address} = Inbox.address(scope)
      {:ok, mail} = Inbox.recent_mail(scope)
      assign(socket, enabled: true, address: Inbox.address_text(address), mail: mail)
    else
      assign(socket, enabled: false, address: nil, mail: [])
    end
  end

  @impl true
  def handle_event("new_address", _, socket) do
    {:ok, _} = Inbox.new_address(socket.assigns.current_scope)

    {:noreply,
     socket |> put_flash(:info, "Tab made a new address. Update your filters.") |> load()}
  end

  defp mail_status(%{kind: "gmail_check", detail: code}), do: "Gmail's code: #{code}"
  defp mail_status(%{status: "stored", detail: "already sent"}), do: "already here"
  defp mail_status(%{status: "stored"}), do: "added to your bills to check"
  defp mail_status(%{status: "fetching"}), do: "arriving"
  defp mail_status(%{detail: detail}) when is_binary(detail), do: detail
  defp mail_status(_), do: "Tab couldn't add it"
end
