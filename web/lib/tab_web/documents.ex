defmodule TabWeb.Documents do
  @moduledoc """
  The list of what arrived about a bill: each document's kind, who sent it,
  when, and the amount. While the original is still here (before the bill is
  saved or dropped) its owner can open it; after that, a search line finds it
  in the mailbox it came from.
  """
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: TabWeb.Endpoint, router: TabWeb.Router

  alias Phoenix.LiveView.JS

  attr :documents, :list, required: true
  attr :id, :string, required: true
  attr :split, :boolean, default: false, doc: "offer \"Not part of this bill\" on each"

  def list(assigns) do
    ~H"""
    <ul id={@id} class="divide-y divide-line text-sm">
      <li :for={d <- @documents} id={"doc-#{d.id}"} class="py-2">
        <span class="block">
          <span class="font-semibold">{role(d)}</span>
          <TabWeb.CoreComponents.money :if={d.amount_cents} cents={d.amount_cents} class="ml-1" />
          <span :if={is_nil(d.purged_at)} class="ml-1">
            · <a href={~p"/documents/#{d.id}"} target="_blank" class="underline">open it</a>
          </span>
        </span>
        <span class="block text-ink-soft">
          {Enum.join(Enum.reject([d.sender, d.subject, sent(d)], &is_nil/1), " · ")}
        </span>
        <button
          :if={@split}
          type="button"
          phx-click="split"
          phx-value-id={d.id}
          class="mt-1 text-xs underline"
        >
          Not part of this bill
        </button>
        <span :if={d.search && d.purged_at} class="mt-1 flex flex-wrap items-center gap-2">
          <input
            id={"search-#{d.id}"}
            readonly
            value={d.search}
            class="tab-field min-w-0 flex-1 text-xs"
            aria-label="Search line for finding this email"
            phx-click={JS.dispatch("tab:select")}
          />
          <button
            type="button"
            class="clay-chip px-2 py-1 text-xs"
            phx-click={JS.dispatch("tab:copy", to: "#search-#{d.id}")}
          >
            Copy search
          </button>
        </span>
      </li>
    </ul>
    """
  end

  @doc "What a document is, in a few words."
  def role(%{role: "bill", kind: "email"}), do: "The bill (email)"
  def role(%{role: "bill"}), do: "The bill"
  def role(%{role: "notice"}), do: "Bill is ready"
  def role(%{role: "autopay_scheduled"}), do: "Autopay scheduled"
  def role(%{role: "payment"}), do: "Payment went through"
  def role(%{role: "reminder"}), do: "Reminder"
  def role(%{kind: "photo"}), do: "A photo"
  def role(%{kind: "pdf"}), do: "A PDF"
  def role(_), do: "An email"

  defp sent(%{sent_at: %NaiveDateTime{} = at}),
    do: Calendar.strftime(at, "%b %-d, %Y")

  defp sent(_), do: nil
end
