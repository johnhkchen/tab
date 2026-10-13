defmodule TabWeb.InboxLive.Index do
  @moduledoc """
  Bills to check (docs/specification.md, "Review"): photos, PDFs, and
  forwarded emails Tab has read, each waiting for its person to check it and
  save it as an expense, or drop it. Photos are shrunk in the browser before
  they upload, so a phone picture arrives small and as a JPEG.
  """
  use TabWeb, :live_view

  alias Tab.Inbox
  alias Tab.Inbox.Mail

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Bills to check
        <:subtitle>
          Send Tab a bill and it fills in the expense for you. Nothing counts until you check it and save it.
        </:subtitle>
      </.header>

      <.card title="Add a bill" id="add">
        <form id="upload_form" phx-change="validate" phx-submit="noop">
          <.live_file_input upload={@uploads.bills} class="sr-only" />
          <input
            id="bill_picker"
            type="file"
            accept="image/*,application/pdf"
            multiple
            class="sr-only"
            phx-hook=".ShrinkPhotos"
          />
          <div class="flex flex-wrap items-center gap-2">
            <label for="bill_picker" class="clay-button cursor-pointer px-4 py-2">
              Take a photo or pick a file
            </label>
            <.link navigate={~p"/inbox/forwarding"} class="clay-chip px-3 py-1.5 text-sm">
              Forward bills by email
            </.link>
          </div>
          <p class="mt-2 text-sm text-ink-soft">A photo of a receipt, or a PDF of up to 10 pages.</p>
          <ul :if={@uploads.bills.entries != []} class="mt-3 space-y-1 text-sm">
            <li :for={entry <- @uploads.bills.entries}>
              {entry.client_name} · {entry.progress}%
              <span :for={err <- upload_errors(@uploads.bills, entry)} class="text-warn">
                {upload_error(err)}
              </span>
            </li>
          </ul>
          <p :for={err <- upload_errors(@uploads.bills)} class="mt-2 text-sm text-warn">
            {upload_error(err)}
          </p>
        </form>
      </.card>

      <p :if={@items == []} class="text-ink-soft" id="empty">
        Nothing to check.
      </p>

      <ul id="items" class="space-y-3">
        <li :for={item <- @items} id={"item-#{item.id}"}>
          <.link
            navigate={~p"/inbox/#{item}"}
            class="clay-surface flex flex-wrap items-center justify-between gap-3 p-5 hover:-translate-y-px"
          >
            <span class="min-w-0">
              <span class="block font-semibold">{title(item)}</span>
              <span class="block text-sm text-ink-soft">{summary(item)}</span>
            </span>
            <span class="flex flex-wrap items-center gap-2 text-right">
              <span :if={item.proposal["past_due"]} class="clay-chip px-2 py-0.5 text-xs text-warn">
                Past due
              </span>
              <span
                :if={Mail.due_soon?(item.due_on, @digest_days, @today)}
                class="clay-chip px-2 py-0.5 text-xs text-warn"
              >
                Due soon
              </span>
              <.money
                :if={item.proposal["total_cents"]}
                cents={item.proposal["total_cents"]}
                class="font-semibold"
              />
            </span>
          </.link>
        </li>
      </ul>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ShrinkPhotos">
        // Photos become JPEGs no wider or taller than 1600 px before uploading.
        const MAX = 1600
        async function shrink(file) {
          if (!file.type.startsWith("image/")) return file
          try {
            const bitmap = await createImageBitmap(file)
            const scale = Math.min(1, MAX / Math.max(bitmap.width, bitmap.height))
            const canvas = document.createElement("canvas")
            canvas.width = Math.round(bitmap.width * scale)
            canvas.height = Math.round(bitmap.height * scale)
            canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
            const blob = await new Promise(ok => canvas.toBlob(ok, "image/jpeg", 0.85))
            const name = file.name.replace(/\.[^.]+$/, "") + ".jpg"
            return new File([blob], name, {type: "image/jpeg"})
          } catch (_e) {
            return file
          }
        }
        export default {
          mounted() {
            this.el.addEventListener("change", async () => {
              const files = await Promise.all([...this.el.files].map(shrink))
              this.upload("bills", files)
              this.el.value = ""
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    profile = Tab.Accounts.get_profile(socket.assigns.current_scope)
    if connected?(socket), do: Inbox.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(
       page_title: "Bills to check",
       digest_days: profile.digest_days,
       today: Date.utc_today()
     )
     |> allow_upload(:bills,
       accept: ~w(.pdf .jpg .jpeg .png .webp .gif),
       max_entries: 5,
       max_file_size: Inbox.max_bytes(:pdf),
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> load()}
  end

  defp load(socket) do
    {:ok, items} = Inbox.list_items(socket.assigns.current_scope)
    assign(socket, items: items)
  end

  @impl true
  def handle_info(:inbox_changed, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  defp handle_progress(:bills, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok,
           Inbox.upload(socket.assigns.current_scope, %{
             content_type: entry.client_type,
             filename: entry.client_name,
             data: File.read!(path)
           })}
        end)

      {:noreply, socket |> flash_for(result, entry.client_name) |> load()}
    else
      {:noreply, socket}
    end
  end

  defp flash_for(socket, {:ok, _}, _name),
    do: put_flash(socket, :info, "Got it. Tab is reading it.")

  defp flash_for(socket, {:error, :duplicate}, name),
    do: put_flash(socket, :error, "You already sent #{name}.")

  defp flash_for(socket, {:error, :too_big}, name),
    do:
      put_flash(socket, :error, "#{name} is too big. Photos can be up to 2 MB, PDFs up to 10 MB.")

  defp flash_for(socket, {:error, _}, name),
    do: put_flash(socket, :error, "Tab can't read #{name}. Send a photo or a PDF.")

  defp upload_error(:too_large), do: "too big (10 MB at most)"
  defp upload_error(:not_accepted), do: "send a photo or a PDF"
  defp upload_error(:too_many_files), do: "five at a time"
  defp upload_error(_), do: "didn't upload"

  @doc false
  def title(item), do: item.proposal["merchant"] || source_name(item)

  defp source_name(%{source: "email"}), do: "A forwarded email"
  defp source_name(%{documents: [%{kind: "pdf"} | _]}), do: "A PDF"
  defp source_name(_), do: "A photo"

  @doc false
  def summary(item) do
    [
      status(item),
      length(item.documents) > 1 && "#{length(item.documents)} documents",
      item.due_on && "due #{format_date(item.due_on)}",
      item.duplicate_of && "looks like one already added"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp status(%{status: "reading"}), do: "Reading it…"
  defp status(%{status: "waiting", note: note}) when is_binary(note), do: String.capitalize(note)
  defp status(%{status: "waiting"}), do: "Waiting for tomorrow's reading"

  defp status(%{status: "unreadable", note: note}),
    do: "Fill it in by hand (#{note || "couldn't read it"})"

  defp status(%{status: "ready"}), do: "Ready to check"
end
