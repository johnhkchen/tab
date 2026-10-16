defmodule TabWeb.ProfileLive do
  @moduledoc """
  Your name and how people can pay you. Both are shown to everyone you share a
  group with, and to nobody else.
  """
  use TabWeb, :live_view

  alias Tab.Accounts
  alias Tab.Ledger.Payment

  @kinds [
    {"Venmo", "venmo"},
    {"Zelle", "zelle"},
    {"Cash App", "cashapp"},
    {"PayPal", "paypal"},
    {"Cash", "cash"},
    {"Check", "check"},
    {"Something else", "other"}
  ]

  @digests [
    {"10-25", "On the 10th and the 25th", [10, 25]},
    {"1-15", "On the 1st and the 15th", [1, 15]},
    {"1", "On the 1st", [1]},
    {"each", "As each bill arrives", []}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        You
        <:subtitle>
          People you share a group with see your name and payment handles. Nobody else does.
        </:subtitle>
      </.header>

      <.form for={@form} id="profile_form" phx-change="change" phx-submit="save" class="space-y-6">
        <.card title="Your name">
          <.input field={@form[:display_name]} label="Name" required />
        </.card>

        <.card title="How to pay you">
          <p class="mb-4 text-ink-soft">
            Whoever settles up with you sees these, so they don't have to ask.
          </p>
          <div
            :for={{method, i} <- Enum.with_index(@methods)}
            class="mb-3 flex flex-wrap items-end gap-2"
          >
            <div class="w-36">
              <.input
                type="select"
                name={"methods[#{i}][kind]"}
                id={"method-kind-#{i}"}
                label={if i == 0, do: "Kind"}
                options={@kinds}
                value={method["kind"]}
              />
            </div>
            <div class="min-w-40 flex-1">
              <.input
                name={"methods[#{i}][handle]"}
                id={"method-handle-#{i}"}
                label={if i == 0, do: "Handle"}
                value={method["handle"]}
                placeholder="@your-name, phone, or email"
              />
            </div>
            <button
              type="button"
              phx-click="remove"
              phx-value-index={i}
              class="mb-3 px-2 py-2 text-ink-soft hover:text-ink"
              aria-label="Remove this one"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <.button type="button" variant="soft" phx-click="add">Add a way to pay you</.button>
          <.error :for={msg <- @method_errors}>{msg}</.error>
        </.card>

        <.button class="w-full sm:w-auto" phx-disable-with="Saving…">Save</.button>
      </.form>

      <.card title="Bills to check" id="digest">
        <p class="mb-3 text-ink-soft">
          Tab emails you about bills waiting for you to check. A bill due before then gets its own email.
        </p>
        <form id="digest_form" phx-submit="save_digest" class="flex flex-wrap items-end gap-2">
          <div class="min-w-48 flex-1">
            <.input
              name="digest"
              id="digest_days"
              type="select"
              label="Email me"
              options={@digest_options}
              value={digest_key(@profile.digest_days)}
            />
          </div>
          <.button variant="soft" class="mb-2">Save</.button>
        </form>
      </.card>

      <.card :if={@mcp} title="Use Tab from Claude" id="claude">
        <p class="mb-3 text-ink-soft">
          Ask Claude what you owe, or tell it what you spent. It works as you, on your own Claude plan.
        </p>
        <label for="claude-command" class="text-sm">In Claude Code, run:</label>
        <input
          id="claude-command"
          readonly
          value={@claude_command}
          class="tab-field font-mono text-sm"
          phx-click={JS.dispatch("tab:select")}
        />
        <.button
          variant="soft"
          class="mt-2"
          phx-click={JS.dispatch("tab:copy", to: "#claude-command")}
        >
          Copy
        </.button>
        <label for="claude-address" class="mt-3 block text-sm">
          In Claude Desktop or claude.ai, add a custom connector with this address:
        </label>
        <input
          id="claude-address"
          readonly
          value={@mcp_address}
          class="tab-field font-mono text-sm"
          phx-click={JS.dispatch("tab:select")}
        />
        <.button
          variant="soft"
          class="mt-2"
          phx-click={JS.dispatch("tab:copy", to: "#claude-address")}
        >
          Copy
        </.button>

        <h3 class="mt-5 font-semibold">Connected</h3>
        <p :if={@connections == []} class="text-ink-soft" id="no-connections">Nothing yet.</p>
        <ul class="divide-y divide-line">
          <li
            :for={c <- @connections}
            id={"connection-#{c.id}"}
            class="flex flex-wrap items-center justify-between gap-2 py-2"
          >
            <span>
              <span class="block">{c.client.name}</span>
              <span class="block text-sm text-ink-soft">
                {if "tab:write" in c.scopes,
                  do: "Can add expenses and payments",
                  else: "Can only look"} · connected {format_date(c.inserted_at)} · {if c.last_used_at,
                  do: "last used #{format_date(c.last_used_at)}",
                  else: "not used yet"}
              </span>
            </span>
            <.button
              variant="soft"
              id={"disconnect-#{c.id}"}
              phx-click="disconnect"
              phx-value-id={c.id}
              data-confirm={"Disconnect #{c.client.name}? It stops working at once."}
            >
              Disconnect
            </.button>
          </li>
        </ul>
      </.card>

      <.card title="Your account">
        <div class="flex flex-wrap gap-2">
          <.button variant="soft" navigate={~p"/users/settings"}>Email and password</.button>
          <.button variant="soft" href={~p"/export.csv"}>Download everything (CSV)</.button>
        </div>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    profile = Accounts.get_profile(socket.assigns.current_scope)

    {:ok,
     assign(socket,
       profile: profile,
       form: to_form(Accounts.change_profile(profile)),
       methods: profile.payment_methods,
       method_errors: [],
       kinds: @kinds,
       digest_options: Enum.map(@digests, fn {key, label, _} -> {label, key} end),
       page_title: "You"
     )
     |> load_connections()}
  end

  defp load_connections(socket) do
    if Tab.OAuth.enabled?() do
      {:ok, connections} = Tab.OAuth.list_connections(socket.assigns.current_scope)

      assign(socket,
        mcp: true,
        connections: connections,
        mcp_address: Tab.OAuth.resource(),
        claude_command: "claude mcp add --transport http tab #{Tab.OAuth.resource()}"
      )
    else
      assign(socket, mcp: false, connections: [])
    end
  end

  @impl true
  def handle_event("change", params, socket) do
    {:noreply,
     assign(socket,
       methods: methods_from(params),
       form: to_form(Accounts.change_profile(socket.assigns.profile, params["profile"] || %{}))
     )}
  end

  def handle_event("save_digest", %{"digest" => key}, socket) do
    days = Enum.find_value(@digests, [10, 25], fn {k, _, days} -> k == key && days end)

    case Accounts.update_digest_days(socket.assigns.current_scope, days) do
      {:ok, profile} ->
        {:noreply, socket |> assign(profile: profile) |> put_flash(:info, "Saved.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That didn't save. Try again.")}
    end
  end

  def handle_event("disconnect", %{"id" => id}, socket) do
    case Tab.OAuth.disconnect(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Disconnected.") |> load_connections()}
      {:error, _} -> {:noreply, load_connections(socket)}
    end
  end

  def handle_event("add", _, socket) do
    {:noreply, update(socket, :methods, &(&1 ++ [%{"kind" => "venmo", "handle" => ""}]))}
  end

  def handle_event("remove", %{"index" => i}, socket) do
    {:noreply, update(socket, :methods, &List.delete_at(&1, String.to_integer(i)))}
  end

  def handle_event("save", params, socket) do
    methods = params |> methods_from() |> Enum.reject(&(String.trim(&1["handle"]) == ""))
    attrs = Map.put(params["profile"] || %{}, "payment_methods", methods)

    case Accounts.update_profile(socket.assigns.current_scope, attrs) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(profile: profile, methods: profile.payment_methods, method_errors: [])
         |> assign(form: to_form(Accounts.change_profile(profile)))
         |> put_flash(:info, "Saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(changeset),
           method_errors:
             Keyword.get_values(changeset.errors, :payment_methods) |> Enum.map(&elem(&1, 0))
         )}
    end
  end

  defp digest_key(days),
    do: Enum.find_value(@digests, "custom", fn {k, _, d} -> d == days && k end)

  defp methods_from(params) do
    (params["methods"] || %{})
    |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
    |> Enum.map(fn {_, m} ->
      %{
        "kind" => (m["kind"] in Payment.methods() && m["kind"]) || "other",
        "handle" => m["handle"] || ""
      }
    end)
  end
end
