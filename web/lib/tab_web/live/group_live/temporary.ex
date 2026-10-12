defmodule TabWeb.GroupLive.Temporary do
  @moduledoc """
  Temporary splits: when someone's away or a guest stays, bills in a category
  split differently for a while, then go back on their own. Admins set them;
  everyone can see them. Two that would cover the same bills on the same days
  get combined only after the admin confirms how.
  """
  use TabWeb, :live_view

  alias Tab.Bills
  alias TabWeb.{GroupData, SplitEditor}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/groups/#{@data.group}"}>{@data.group.name}</.back>
      <.header>
        Temporary splits
        <:subtitle>
          Someone away, or a guest staying? Split bills another way for a while.
          It stops on its own when the dates end.
        </:subtitle>
      </.header>

      <.card id="overrides">
        <p :if={@overrides == []} class="text-ink-soft">
          None yet. Bills split the usual way.
        </p>
        <ul class="divide-y divide-line">
          <li :for={o <- @overrides} id={"override-#{o.id}"} class="py-3">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <span class="min-w-0">
                <span class="font-semibold">{o.note || "Temporary split"}</span>
                <span class="clay-chip ml-1 px-2 py-0.5 text-xs">{status(o, @today)}</span>
                <span class="block text-sm text-ink-soft">
                  {dates(o)} · {GroupData.category_name(@data, o.category_id) || "All bills"}
                </span>
                <span class="block text-sm text-ink-soft">{SplitEditor.describe(o.split, @data)}</span>
              </span>
              <span :if={@can_edit} class="flex flex-wrap gap-2 text-sm">
                <button phx-click="edit" phx-value-id={o.id} class="clay-chip px-3 py-1">Change</button>
                <button
                  phx-click="remove"
                  phx-value-id={o.id}
                  data-confirm="Remove this? Bills already saved keep their split."
                  class="px-2 py-1 text-warn underline"
                >
                  Remove
                </button>
              </span>
            </div>
          </li>
        </ul>
        <p :if={!@data.admin?} class="mt-3 text-sm text-ink-soft">
          Only admins set these.
        </p>
      </.card>

      <.card :if={@plan} title="This overlaps" id="clash">
        <p :for={o <- @clashes} class="mb-2">
          <span class="font-semibold">{o.note || "A temporary split"}</span>
          covers the same bills, {dates(o)}.
        </p>
        <div :if={match?({:ok, _}, @plan)}>
          <p class="mb-2">Tab can save them side by side, like this:</p>
          <ul class="mb-4 divide-y divide-line" id="plan">
            <li :for={p <- elem(@plan, 1).pieces} class="py-2">
              <span class="font-semibold">{piece_dates(p)}</span>
              <span :if={p.kind == :both} class="clay-chip ml-1 px-2 py-0.5 text-xs">Both</span>
              <span class="block text-sm text-ink-soft">
                {p.note || "Temporary split"} · {SplitEditor.describe(p.split, @data)}
              </span>
            </li>
          </ul>
          <p class="mb-4 text-sm text-ink-soft">
            On the days both apply, anyone left out of either one stays out.
          </p>
          <div class="flex flex-wrap gap-2">
            <.button phx-click="confirm_plan">Save it this way</.button>
            <.button variant="soft" phx-click="back">Go back</.button>
          </div>
        </div>
        <div :if={match?({:error, _}, @plan)}>
          <p class="mb-4">{plan_problem(@plan)}</p>
          <.button variant="soft" phx-click="back">Go back</.button>
        </div>
      </.card>

      <form
        :if={@can_edit && !@plan}
        id="override_form"
        phx-change="change"
        phx-submit="save"
        class="space-y-6"
      >
        <.card title={if @editing, do: "Change it", else: "Add a temporary split"}>
          <.input
            :if={!@editing}
            name="o[away]"
            id="o_away"
            type="select"
            label="Someone's away?"
            hint="Pick them and Tab fills in a split without them. You can still change it."
            options={Enum.map(@data.members, &{GroupData.name_user(@data, &1.user_id), &1.user_id})}
            prompt="No, I'll set the split myself"
            value={@f["away"]}
          />
          <.input
            name="o[note]"
            id="o_note"
            label="What's it for?"
            value={@f["note"]}
            errors={@errors[:note] || []}
            placeholder="Alex away, Guest staying…"
          />
          <div class="grid grid-cols-1 gap-x-4 sm:grid-cols-3">
            <.input
              name="o[category_id]"
              id="o_category"
              type="select"
              label="Which bills?"
              options={Enum.map(@data.categories, &{&1.name, &1.id})}
              prompt="All bills"
              value={@f["category_id"]}
            />
            <.input
              name="o[effective_from]"
              id="o_from"
              type="date"
              label="From"
              value={@f["effective_from"]}
              errors={@errors[:effective_from] || []}
            />
            <.input
              name="o[effective_until]"
              id="o_until"
              type="date"
              label="Until (optional)"
              value={@f["effective_until"]}
              errors={@errors[:effective_until] || []}
            />
          </div>
        </.card>

        <.card title="How to split those bills">
          <SplitEditor.split_fields data={@data} state={@split} error={@split_error} />
        </.card>

        <div class="flex flex-wrap gap-2">
          <.button phx-disable-with="Saving…">{if @editing, do: "Save changes", else: "Add it"}</.button>
          <.button :if={@editing} type="button" variant="soft" phx-click="cancel">Cancel</.button>
        </div>
      </form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"group_id" => group_id}, _session, socket) do
    data = GroupData.load!(socket.assigns.current_scope, group_id)

    {:ok,
     socket
     |> assign(
       data: data,
       can_edit: data.admin? and not data.archived?,
       today: Date.utc_today(),
       page_title: "Temporary splits"
     )
     |> reset()
     |> load()}
  end

  defp load(socket) do
    %{current_scope: scope, data: data} = socket.assigns
    {:ok, overrides} = Bills.list_overrides(scope, data.group.id)
    {:ok, templates} = Bills.list_templates(scope, data.group.id)
    assign(socket, overrides: overrides, templates: templates)
  end

  defp reset(socket) do
    assign(socket,
      editing: nil,
      plan: nil,
      clashes: [],
      pending: nil,
      errors: %{},
      split_error: nil,
      split: SplitEditor.new_state(socket.assigns.data),
      f: %{
        "away" => "",
        "note" => "",
        "category_id" => "",
        "effective_from" => Date.to_iso8601(Date.utc_today()),
        "effective_until" => ""
      }
    )
  end

  @impl true
  def handle_event("change", params, socket) do
    before = socket.assigns.f
    socket = read(socket, params)
    f = socket.assigns.f

    # Picking who's away (or changing which bills) proposes a split without them.
    if f["away"] != "" and
         (f["away"] != before["away"] or f["category_id"] != before["category_id"]) do
      {:noreply, propose(socket, before)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", params, socket) do
    socket = read(socket, params)
    %{data: data, current_scope: scope, editing: editing} = socket.assigns

    with {:split, {:ok, split}} <- {:split, SplitEditor.build(socket.assigns.split, data)},
         {:dates, {:ok, attrs}} <- {:dates, attrs(socket.assigns.f, split)} do
      result =
        if editing,
          do: Bills.update_override(scope, editing.id, attrs),
          else: Bills.create_override(scope, data.group.id, attrs)

      case result do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, "Saved.") |> reset() |> load()}

        {:error, :override_overlap} ->
          {:noreply, socket |> load() |> clash(attrs)}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, assign(socket, errors: errors(cs), split_error: split_error(cs))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "That didn't save. Try again.")}
      end
    else
      {:split, {:error, message}} ->
        {:noreply, assign(socket, split_error: message)}

      {:dates, {:error, field, message}} ->
        {:noreply, assign(socket, errors: %{field => [message]})}
    end
  end

  def handle_event("confirm_plan", _, socket) do
    %{plan: {:ok, plan}, pending: attrs, data: data, current_scope: scope} = socket.assigns

    case Bills.apply_plan(scope, data.group.id, attrs, plan) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Saved side by side.") |> reset() |> load()}

      {:error, _} ->
        {:noreply,
         socket
         |> load()
         |> assign(plan: nil)
         |> put_flash(:error, "Something changed while you were looking. Try again.")}
    end
  end

  def handle_event("back", _, socket), do: {:noreply, assign(socket, plan: nil, clashes: [])}
  def handle_event("cancel", _, socket), do: {:noreply, reset(socket)}

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.overrides, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      o ->
        {:noreply,
         socket
         |> reset()
         |> assign(
           editing: o,
           split: SplitEditor.state(o.split, socket.assigns.data),
           f: %{
             "away" => "",
             "note" => o.note || "",
             "category_id" => o.category_id || "",
             "effective_from" => Date.to_iso8601(o.effective_from),
             "effective_until" =>
               if(o.effective_until, do: Date.to_iso8601(o.effective_until), else: "")
           }
         )}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Bills.delete_override(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Removed.") |> reset() |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "That can't be removed.")}
    end
  end

  defp read(socket, params) do
    f = Map.merge(socket.assigns.f, Map.take(params["o"] || %{}, Map.keys(socket.assigns.f)))
    assign(socket, f: f, split: SplitEditor.read(socket.assigns.split, params))
  end

  defp propose(socket, before) do
    %{data: data, templates: templates, f: f} = socket.assigns
    party = {:user, f["away"]}
    member_ids = Enum.map(data.members, & &1.user_id)

    case Bills.away_split(templates, blank(f["category_id"]), member_ids, party) do
      nil ->
        assign(socket, split_error: "There's nobody left to split with.")

      split ->
        name = GroupData.name_user(data, f["away"])

        note =
          if f["note"] in ["", note_for(data, before["away"])],
            do: "#{name} away",
            else: f["note"]

        assign(socket,
          split: SplitEditor.state(split, data),
          split_error: nil,
          f: Map.put(f, "note", note)
        )
    end
  end

  defp note_for(_data, ""), do: ""
  defp note_for(data, id), do: "#{GroupData.name_user(data, id)} away"

  # Shows what it overlaps and, for a new one, how Tab would save them together.
  defp clash(socket, attrs) do
    clashes =
      Bills.clashes(
        socket.assigns.overrides,
        attrs,
        socket.assigns.editing && socket.assigns.editing.id
      )

    plan =
      cond do
        clashes == [] -> {:error, :gone}
        socket.assigns.editing -> {:error, :editing}
        true -> Bills.plan_combine(attrs, clashes)
      end

    assign(socket, clashes: clashes, plan: plan, pending: attrs)
  end

  defp plan_problem({:error, :different_bills}),
    do:
      "One of these covers all bills and the other covers one category, so Tab can't put them side by side. Change the dates or the bills on one of them first."

  defp plan_problem({:error, :nobody_in_both}),
    do: "On the days both apply, nobody is in both splits. Change the dates or the split first."

  defp plan_problem({:error, :editing}),
    do: "Change the dates so they don't overlap, or remove the other one first."

  defp plan_problem(_), do: "Something changed while you were looking. Go back and try again."

  defp attrs(f, split) do
    with {:ok, from} <- date(f["effective_from"], :effective_from, "pick a start date"),
         {:ok, until} <- optional_date(f["effective_until"]) do
      {:ok,
       %{
         category_id: blank(f["category_id"]),
         effective_from: from,
         effective_until: until,
         split: split,
         note: blank(String.trim(f["note"] || ""))
       }}
    end
  end

  defp date(text, field, message) do
    case Date.from_iso8601(text || "") do
      {:ok, d} -> {:ok, d}
      _ -> {:error, field, message}
    end
  end

  defp optional_date(""), do: {:ok, nil}
  defp optional_date(nil), do: {:ok, nil}
  defp optional_date(text), do: date(text, :effective_until, "pick a date, or leave it empty")

  defp blank(""), do: nil
  defp blank(v), do: v

  defp errors(cs) do
    Enum.group_by(cs.errors, &elem(&1, 0), fn {_, e} ->
      TabWeb.CoreComponents.translate_error(e)
    end)
  end

  defp split_error(cs) do
    case Keyword.get_values(cs.errors, :split) do
      [e | _] -> TabWeb.CoreComponents.translate_error(e)
      [] -> nil
    end
  end

  defp status(o, today) do
    cond do
      Date.compare(o.effective_from, today) == :gt -> "Coming"
      o.effective_until && Date.compare(o.effective_until, today) == :lt -> "Ended"
      true -> "Now"
    end
  end

  defp dates(%{effective_from: from, effective_until: nil}),
    do: "from #{format_date(from)}, no end date"

  defp dates(%{effective_from: from, effective_until: to}),
    do: "#{format_date(from)} to #{format_date(to)}"

  defp piece_dates(%{from: from, to: nil}), do: "From #{format_date(from)}"
  defp piece_dates(%{from: from, to: to}), do: "#{format_date(from)} to #{format_date(to)}"
end
