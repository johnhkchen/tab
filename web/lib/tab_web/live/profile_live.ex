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
            Shown when someone settles up with you, so they don't have to ask.
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
       page_title: "You"
     )}
  end

  @impl true
  def handle_event("change", params, socket) do
    {:noreply,
     assign(socket,
       methods: methods_from(params),
       form: to_form(Accounts.change_profile(socket.assigns.profile, params["profile"] || %{}))
     )}
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
