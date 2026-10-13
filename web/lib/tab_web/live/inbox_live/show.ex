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

      <.card :if={@hint} id="forwarder-hint">
        <p>
          {@hint} sent bills from two different companies. Is it someone who forwards bills to you,
          like a landlord?
        </p>
        <.button variant="soft" class="mt-2" phx-click="add_forwarder">
          Yes: read the company from the bill
        </.button>
      </.card>

      <.card :if={@others != []} title="Same bill as another?" id="join">
        <form id="join_form" phx-submit="join" class="flex flex-wrap items-end gap-2">
          <div class="min-w-48 flex-1">
            <.input
              name="target"
              id="join_target"
              type="select"
              label="Put it together with"
              options={@others}
              value={elem(hd(@others), 1)}
            />
          </div>
          <.button variant="soft" class="mb-2">Put together</.button>
        </form>
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
          split
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

    scope = socket.assigns.current_scope
    {:ok, open} = Inbox.list_items(scope)

    others =
      for i <- open, i.id != item.id, i.status != "reading" do
        amount = i.proposal["period_cents"] || i.proposal["total_cents"]

        label =
          Enum.join(
            Enum.reject([Index.title(i), amount && TabWeb.Format.money(amount)], &is_nil/1),
            ", "
          )

        {label, i.id}
      end

    hint =
      with sender when is_binary(sender) <- item.proposal["suggest_forwarder"],
           gid when is_binary(gid) <- item.group_id,
           {:ok, fs} <- Tab.Bills.list_forwarders(scope, gid),
           false <- Enum.any?(fs, &(&1.address == sender)) do
        sender
      else
        _ -> nil
      end

    assign(socket,
      item: item,
      main: main,
      email: email,
      attachment: attachment,
      others: others,
      hint: hint
    )
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

  def handle_event("join", %{"target" => target}, socket) do
    case Inbox.join(socket.assigns.current_scope, socket.assigns.item.id, target) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Put together.") |> push_navigate(to: ~p"/inbox/#{target}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That didn't work. Try again.")}
    end
  end

  def handle_event("split", %{"id" => doc_id}, socket) do
    case Inbox.split(socket.assigns.current_scope, socket.assigns.item.id, doc_id) do
      {:ok, _} ->
        {:ok, item} = Inbox.get_item(socket.assigns.current_scope, socket.assigns.item.id)

        {:noreply,
         socket
         |> put_flash(:info, "Taken out. It's its own bill to check now.")
         |> assign_item(item)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That didn't work. Try again.")}
    end
  end

  def handle_event("add_forwarder", _, socket) do
    %{item: item, hint: sender, current_scope: scope} = socket.assigns

    case Tab.Bills.add_forwarder(scope, item.group_id, sender) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Added. Tab reads the company from their bills now.")
         |> assign(hint: nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That didn't save. Try again.")}
    end
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
