defmodule TabWeb.InboxLive.Show do
  @moduledoc """
  One bill to check: the original next to what Tab read from it. Picking a
  group opens the add-expense form filled in from it (`?item=`), so saving
  works exactly like an expense typed in by hand. Dropping it deletes the
  original.
  """
  use TabWeb, :live_view

  alias Tab.{Groups, Inbox}
  alias Tab.Inbox.Email
  alias TabWeb.InboxLive.Index

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/inbox"}>Bills to check</.back>
      <.header>
        {Index.title(@item)}
        <:subtitle>{Index.summary(@item)}</:subtitle>
      </.header>

      <.card title="What Tab read" id="reading">
        <p :if={@item.status == "reading"} class="text-ink-soft">
          Tab is reading it. This page updates when it's done.
        </p>
        <dl :if={@item.status != "reading"} class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
          <.row label="From">{@item.proposal["merchant"] || "?"}</.row>
          <.row label="Amount">
            <.money :if={@item.proposal["total_cents"]} cents={@item.proposal["total_cents"]} />
            <span :if={!@item.proposal["total_cents"]}>?</span>
          </.row>
          <.row :if={@item.proposal["date"]} label="Dated">{@item.proposal["date"]}</.row>
          <.row :if={@item.due_on} label="Due">{format_date(@item.due_on)}</.row>
          <.row :if={@item.proposal["period_start"]} label="Covers">
            {@item.proposal["period_start"]} to {@item.proposal["period_end"]}
          </.row>
        </dl>
        <p :if={@item.proposal["past_due"]} class="mt-3 text-warn" id="past-due">
          The bill says the account is past due. Check that autopay is still on.
        </p>
        <p :if={@item.proposal["previous_cents"]} class="mt-3 text-sm" id="carried">
          It includes <.money cents={@item.proposal["previous_cents"]} /> carried over from an earlier
          bill. Tab fills in this period's charges; you can add the rest when you save.
        </p>
        <p :if={@item.duplicate_of} class="mt-3 text-warn" id="duplicate">
          Someone added an expense with the same amount a few days apart. Check it isn't this one.
        </p>
        <ul
          :if={(@item.proposal["line_items"] || []) != []}
          class="mt-3 divide-y divide-line text-sm"
          id="lines"
        >
          <li :for={l <- @item.proposal["line_items"]} class="flex justify-between gap-2 py-1">
            <span>{l["description"]}</span>
            <.money cents={l["cents"]} />
          </li>
        </ul>
      </.card>

      <.card :if={@item.status != "reading"} title="Add it to a group" id="choose">
        <p :if={@groups == []} class="text-ink-soft">
          You're not in a group. <.link navigate={~p"/groups"} class="underline">Start one</.link>
          first.
        </p>
        <form
          :if={@groups != []}
          id="group_form"
          phx-submit="check"
          class="flex flex-wrap items-end gap-2"
        >
          <div class="min-w-48 flex-1">
            <.input
              name="group_id"
              id="group_id"
              type="select"
              label="Which group?"
              options={Enum.map(@groups, &{&1.name, &1.id})}
              value={@item.group_id}
            />
          </div>
          <.button class="mb-2">Check and save</.button>
        </form>
        <button
          phx-click="dismiss"
          data-confirm="Drop this bill? Tab deletes the original."
          class="mt-2 text-sm text-warn underline"
        >
          Not a bill to share: drop it
        </button>
      </.card>

      <.card
        title={
          if length(@item.documents) == 1, do: "The original", else: "What arrived about this bill"
        }
        id="original"
      >
        <TabWeb.Documents.list
          :if={length(@item.documents) > 1}
          documents={@item.documents}
          id="item-documents"
        />
        <img
          :if={@main && @main.kind == "photo"}
          src={~p"/documents/#{@main.id}"}
          alt="The photo you sent"
          class="mt-3 max-h-[32rem] w-full rounded-xl object-contain"
        />
        <p :if={@attachment}>
          <a href={~p"/documents/#{@main.id}?part=attachment"} target="_blank" class="underline">
            Open the attached {if elem(@attachment, 0) == :pdf, do: "PDF", else: "image"}
          </a>
        </p>
        <p :if={@main && @main.kind == "pdf"}>
          <a href={~p"/documents/#{@main.id}"} target="_blank" class="underline">Open the PDF</a>
        </p>
        <div :if={@email} class="mt-3 text-sm">
          <p class="text-ink-soft">
            From {@email.sender || @email.from} · {@email.original_subject || @email.subject}
          </p>
          <pre class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap break-words font-body">{@email.text}</pre>
        </div>
      </.card>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp row(assigns) do
    ~H"""
    <dt class="text-ink-soft">{@label}</dt>
    <dd>{render_slot(@inner_block)}</dd>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, item} <- Inbox.get_item(scope, id),
         true <- item.status in Inbox.open_statuses() do
      if connected?(socket), do: Inbox.subscribe(scope)
      {:ok, groups} = Groups.list_groups(scope)

      {:ok,
       socket
       |> assign(page_title: "Check a bill", groups: Enum.filter(groups, &is_nil(&1.deleted_at)))
       |> assign_item(item)}
    else
      _ -> raise TabWeb.GroupData.NotFound
    end
  end

  # The document shown in full: the bill itself if one arrived, else the first.
  defp assign_item(socket, item) do
    main =
      Enum.find(item.documents, &(&1.role == "bill" and is_nil(&1.purged_at))) ||
        Enum.find(item.documents, &is_nil(&1.purged_at))

    {email, attachment} =
      with %{kind: "email", id: id} <- main,
           {:ok, doc} <- Inbox.content(socket.assigns.current_scope, id),
           {:ok, email} <- Email.parse(doc.content) do
        {email, email.part}
      else
        _ -> {nil, nil}
      end

    assign(socket, item: item, main: main, email: email, attachment: attachment)
  end

  @impl true
  def handle_info(:inbox_changed, socket) do
    case Inbox.get_item(socket.assigns.current_scope, socket.assigns.item.id) do
      {:ok, item} -> {:noreply, assign_item(socket, item)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("check", %{"group_id" => group_id}, socket) do
    {:noreply,
     push_navigate(socket, to: ~p"/groups/#{group_id}/expenses/new?item=#{socket.assigns.item}")}
  end

  def handle_event("dismiss", _, socket) do
    case Inbox.dismiss(socket.assigns.current_scope, socket.assigns.item.id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Dropped.") |> push_navigate(to: ~p"/inbox")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That didn't work. Try again.")}
    end
  end
end
