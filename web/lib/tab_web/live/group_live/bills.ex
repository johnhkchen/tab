defmodule TabWeb.GroupLive.Bills do
  @moduledoc """
  Bills that come back: rent, internet, anything regular. Set one up once,
  then log each new one in a tap. Logging opens the add-expense form filled
  in, so nothing counts until someone saves it.
  """
  use TabWeb, :live_view

  alias Tab.Bills
  alias Tab.Bills.{Dates, Template}
  alias TabWeb.{Format, GroupData, SplitEditor}

  @cadences [
    {"Every month", "monthly"},
    {"Every two months", "bimonthly"},
    {"Every three months", "quarterly"},
    {"Every so many days", "custom_n_days"},
    {"No set schedule", "irregular"}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.back navigate={~p"/groups/#{@data.group}"}>{@data.group.name}</.back>
      <.header>
        Bills
        <:subtitle>
          Rent, internet, anything that comes back. Set it up once, then log each one in a tap.
        </:subtitle>
      </.header>

      <.card id="bills">
        <p :if={@templates == []} class="text-ink-soft">
          No bills yet. Add one below.
        </p>
        <ul class="divide-y divide-line">
          <li
            :for={t <- @templates}
            id={"bill-#{t.id}"}
            class="flex flex-wrap items-center justify-between gap-3 py-3"
          >
            <span class="min-w-0">
              <span class="font-semibold">{t.name}</span>
              <span
                :if={Dates.late?(t.cadence, t.cadence_days, t.last_logged_on, @today)}
                class="clay-chip ml-1 px-2 py-0.5 text-xs text-warn"
              >
                Late
              </span>
              <span class="block text-sm text-ink-soft">{summary(t, @data)}</span>
              <span :if={t.aliases != []} class="block text-sm text-ink-soft">
                Also called {Enum.join(t.aliases, ", ")}
              </span>
            </span>
            <span :if={!@data.archived?} class="flex flex-wrap gap-2">
              <.button navigate={~p"/groups/#{@data.group}/expenses/new?template=#{t.id}"}>
                Log it
              </.button>
              <button phx-click="edit" phx-value-id={t.id} class="clay-chip px-3 py-1 text-sm">
                Change
              </button>
              <button
                phx-click="remove"
                phx-value-id={t.id}
                data-confirm="Stop offering this bill? Bills already logged stay."
                class="px-2 py-1 text-sm text-warn underline"
              >
                Remove
              </button>
            </span>
          </li>
        </ul>
      </.card>

      <.card title="Who forwards bills to you" id="forwarders">
        <p class="mb-3 text-sm text-ink-soft">
          A landlord or property manager who sends bills for several companies. Tab won't mistake
          them for the company; it reads the company from the bill itself.
        </p>
        <ul :if={@forwarders != []} class="mb-3 divide-y divide-line text-sm">
          <li
            :for={f <- @forwarders}
            id={"forwarder-#{f.id}"}
            class="flex items-center justify-between gap-2 py-2"
          >
            <span class="min-w-0 break-all">{f.address}</span>
            <button
              :if={!@data.archived?}
              phx-click="remove_forwarder"
              phx-value-id={f.id}
              class="px-2 py-1 text-warn underline"
            >
              Remove
            </button>
          </li>
        </ul>
        <form
          :if={!@data.archived?}
          id="forwarder_form"
          phx-submit="add_forwarder"
          class="flex flex-wrap items-end gap-2"
        >
          <div class="min-w-48 flex-1">
            <.input
              name="address"
              id="forwarder_address"
              type="email"
              label="Their email address"
              value=""
              errors={@forwarder_errors}
            />
          </div>
          <.button variant="soft" class="mb-2">Add</.button>
        </form>
      </.card>

      <form
        :if={!@data.archived?}
        id="bill_form"
        phx-change="change"
        phx-submit="save"
        class="space-y-6"
      >
        <.card title={if @editing, do: "Change #{@editing.name}", else: "Add a bill"}>
          <.input
            name="bill[name]"
            id="bill_name"
            label="What's it called?"
            value={@f["name"]}
            errors={@errors[:name] || []}
            placeholder="Rent, Internet, Electric…"
          />
          <.input
            name="bill[aliases]"
            id="bill_aliases"
            label="Also called (optional)"
            hint="Other names on its bills, and the addresses they come from, separated by commas. Tab adds ones it sees."
            value={@f["aliases"]}
            placeholder="SFPUC, San Francisco Water, sfwater.org"
          />
          <div class="grid grid-cols-1 gap-x-4 sm:grid-cols-2">
            <.input
              name="bill[category_id]"
              id="bill_category"
              type="select"
              label="Category"
              options={Enum.map(@data.categories, &{&1.name, &1.id})}
              prompt="No category"
              value={@f["category_id"]}
            />
            <.input
              name="bill[cadence]"
              id="bill_cadence"
              type="select"
              label="How often?"
              options={@cadences}
              value={@f["cadence"]}
            />
            <.input
              :if={@f["cadence"] == "custom_n_days"}
              name="bill[cadence_days]"
              id="bill_cadence_days"
              label="Every how many days?"
              value={@f["cadence_days"]}
              errors={@errors[:cadence_days] || []}
              inputmode="numeric"
            />
            <.input
              name="bill[stability]"
              id="bill_stability"
              type="select"
              label="The amount"
              options={[
                {"Changes each time (like electric)", "variable"},
                {"Stays the same (like rent)", "fixed"}
              ]}
              value={@f["stability"]}
            />
            <.input
              name="bill[default_payer]"
              id="bill_payer"
              type="select"
              label="Who usually pays?"
              options={Enum.map(@data.members, &{GroupData.name_user(@data, &1.user_id), &1.user_id})}
              prompt="Whoever logs it"
              value={@f["default_payer"]}
            />
            <.input
              name="bill[autopay_day]"
              id="bill_autopay_day"
              label="Paid automatically on day (optional)"
              hint="The day of the month it leaves the account, 1 to 31."
              value={@f["autopay_day"]}
              errors={@errors[:autopay_day] || []}
              inputmode="numeric"
            />
          </div>
        </.card>

        <.card title="Who's in, and how to split it">
          <SplitEditor.split_fields
            data={@data}
            state={@split}
            types={~w(equal exact percentage shares)}
            error={@split_error}
          />
        </.card>

        <div class="flex flex-wrap gap-2">
          <.button phx-disable-with="Saving…">{if @editing, do: "Save changes", else: "Add bill"}</.button>
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
     |> assign(data: data, cadences: @cadences, page_title: "Bills", today: Date.utc_today())
     |> reset()
     |> load()}
  end

  defp load(socket) do
    %{current_scope: scope, data: data} = socket.assigns
    {:ok, templates} = Bills.list_templates(scope, data.group.id)
    {:ok, forwarders} = Bills.list_forwarders(scope, data.group.id)
    assign(socket, templates: templates, forwarders: forwarders, forwarder_errors: [])
  end

  defp reset(socket) do
    assign(socket,
      editing: nil,
      errors: %{},
      split_error: nil,
      split: SplitEditor.new_state(socket.assigns.data),
      f: %{
        "name" => "",
        "category_id" => "",
        "cadence" => "monthly",
        "cadence_days" => "",
        "stability" => "variable",
        "default_payer" => "",
        "autopay_day" => "",
        "aliases" => ""
      }
    )
  end

  @impl true
  def handle_event("change", params, socket) do
    {:noreply, read(socket, params)}
  end

  def handle_event("save", params, socket) do
    socket = read(socket, params)
    %{data: data, f: f, editing: editing, current_scope: scope} = socket.assigns

    with {:split, {:ok, split}} <- {:split, SplitEditor.build(socket.assigns.split, data)},
         attrs = attrs(f, split),
         {:ok, _} <- save(scope, data, editing, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, if(editing, do: "Saved.", else: "Added. Log it whenever it comes in."))
       |> reset()
       |> load()}
    else
      {:split, {:error, message}} ->
        {:noreply, assign(socket, split_error: message)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, errors: errors(cs), split_error: split_error(cs))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That didn't save. Try again.")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.templates, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      t ->
        {:noreply,
         socket
         |> reset()
         |> assign(
           editing: t,
           split: SplitEditor.state(t.default_split, socket.assigns.data),
           f: %{
             "name" => t.name,
             "category_id" => t.category_id || "",
             "cadence" => t.cadence,
             "cadence_days" => to_string(t.cadence_days || ""),
             "stability" => t.stability,
             "default_payer" => t.default_payer || "",
             "autopay_day" => to_string(t.autopay_day || ""),
             "aliases" => Enum.join(t.aliases, ", ")
           }
         )}
    end
  end

  def handle_event("cancel", _, socket), do: {:noreply, reset(socket)}

  def handle_event("add_forwarder", %{"address" => address}, socket) do
    case Bills.add_forwarder(socket.assigns.current_scope, socket.assigns.data.group.id, address) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Added.") |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket,
           forwarder_errors:
             Keyword.get_values(cs.errors, :address)
             |> Enum.map(&TabWeb.CoreComponents.translate_error/1)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That didn't save. Try again.")}
    end
  end

  def handle_event("remove_forwarder", %{"id" => id}, socket) do
    {:ok, _} = Bills.remove_forwarder(socket.assigns.current_scope, id)
    {:noreply, socket |> put_flash(:info, "Removed.") |> load()}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Bills.delete_template(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Removed.") |> reset() |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "That bill can't be removed.")}
    end
  end

  defp read(socket, params) do
    f = Map.merge(socket.assigns.f, Map.take(params["bill"] || %{}, Map.keys(socket.assigns.f)))
    assign(socket, f: f, split: SplitEditor.read(socket.assigns.split, params))
  end

  defp save(scope, data, nil, attrs), do: Bills.create_template(scope, data.group.id, attrs)
  defp save(scope, _data, t, attrs), do: Bills.update_template(scope, t.id, attrs)

  defp attrs(f, split) do
    %{
      name: f["name"],
      category_id: blank(f["category_id"]),
      cadence: f["cadence"],
      cadence_days: blank(f["cadence_days"]),
      stability: f["stability"],
      default_payer: blank(f["default_payer"]),
      autopay_day: blank(f["autopay_day"]),
      aliases: String.split(f["aliases"] || "", ","),
      default_split: split
    }
  end

  defp blank(""), do: nil
  defp blank(v), do: v

  defp errors(cs) do
    Enum.group_by(cs.errors, &elem(&1, 0), fn {_, e} ->
      TabWeb.CoreComponents.translate_error(e)
    end)
  end

  defp split_error(cs) do
    case Keyword.get_values(cs.errors, :default_split) do
      [e | _] -> TabWeb.CoreComponents.translate_error(e)
      [] -> nil
    end
  end

  defp summary(%Template{} = t, data) do
    [
      cadence_label(t),
      t.last_amount_cents &&
        "#{if t.stability == "fixed", do: "", else: "last "}#{Format.money(t.last_amount_cents)}",
      t.last_logged_on && "logged #{format_date(t.last_logged_on)}",
      late_note(t, data),
      t.autopay_day && "paid automatically on the #{ordinal(t.autopay_day)}",
      t.default_payer && usually_pays(data, t.default_payer)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp late_note(t, _data) do
    if Dates.late?(t.cadence, t.cadence_days, t.last_logged_on, Date.utc_today()),
      do:
        "the next one was due #{format_date(Dates.next_due(t.cadence, t.cadence_days, t.last_logged_on))}; check that it was paid"
  end

  defp usually_pays(%{me: me}, me), do: "you usually pay"
  defp usually_pays(data, id), do: "#{GroupData.name_user(data, id)} usually pays"

  defp cadence_label(%{cadence: "custom_n_days", cadence_days: n}), do: "Every #{n} days"

  defp cadence_label(%{cadence: cadence}),
    do: Enum.find_value(@cadences, fn {label, c} -> c == cadence && label end)

  defp ordinal(n) when n in [11, 12, 13], do: "#{n}th"

  defp ordinal(n) do
    case rem(n, 10) do
      1 -> "#{n}st"
      2 -> "#{n}nd"
      3 -> "#{n}rd"
      _ -> "#{n}th"
    end
  end
end
