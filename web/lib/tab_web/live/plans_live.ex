defmodule TabWeb.PlansLive do
  @moduledoc """
  Your plan on Hosted Tab (docs/specification.md, "Pages"): what you have,
  how many bills Tab read this month, buying Plus through Paddle, managing
  billing in Paddle's portal, and asking for 6 more months of trial. Not on
  self-host.
  """
  use TabWeb, :live_view

  alias Tab.Billing
  alias Tab.Billing.{Account, Paddle}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Your plan
        <:subtitle>{plan_line(@plan)}</:subtitle>
      </.header>

      <.card title="Bill reading" id="reading">
        <p :if={@allowance > 0}>
          Tab read {@used} of your {@allowance} bills this month.
          <span :if={@used >= @allowance} class="block text-ink-soft">
            New bills wait until {format_date(@resumes_on)}, or fill them in yourself.
          </span>
        </p>
        <p :if={@allowance == 0} class="text-ink-soft">
          Tab reads bills on Plus. On Hosted free you can still add bills and forward them, and
          fill them in yourself.
        </p>
      </.card>

      <.card :if={@plan[:source] != :paid} title="Plus, $10 a year" id="buy">
        <p class="mb-3 text-ink-soft">
          Tab reads up to 100 bills a month for you, in every group you're in. Billed once a year
          through Paddle. Full refund within 30 days, no questions.
        </p>
        <.button
          :if={@checkout}
          id="buy-plus"
          phx-hook=".PaddleCheckout"
          data-environment={@checkout.environment}
          data-token={@checkout.token}
          data-price={@checkout.price}
          data-email={@current_scope.user.email}
          data-user={@current_scope.user.id}
        >
          Buy Plus
        </.button>
        <p :if={!@checkout} class="text-ink-soft" id="no-checkout">
          Buying Plus isn't open yet.
        </p>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".PaddleCheckout">
          export default {
            mounted() {
              const ready = () => {
                if (this.el.dataset.environment === "sandbox") Paddle.Environment.set("sandbox")
                Paddle.Initialize({
                  token: this.el.dataset.token,
                  eventCallback: (e) => {
                    if (e.name === "checkout.completed") this.pushEvent("paid", {})
                  }
                })
              }
              if (window.Paddle) ready()
              else {
                const s = document.createElement("script")
                s.src = "https://cdn.paddle.com/paddle/v2/paddle.js"
                s.onload = ready
                document.head.appendChild(s)
              }
              this.el.addEventListener("click", () => {
                if (!window.Paddle) return
                Paddle.Checkout.open({
                  items: [{ priceId: this.el.dataset.price, quantity: 1 }],
                  customer: { email: this.el.dataset.email },
                  customData: { user_id: this.el.dataset.user }
                })
              })
            }
          }
        </script>
      </.card>

      <.card :if={@customer?} title="Billing" id="billing">
        <p class="mb-3 text-ink-soft">
          Cancel, change your card, or get receipts in Paddle's billing page.
        </p>
        <.button variant="soft" phx-click="portal" id="portal">Manage billing</.button>
      </.card>

      <.card :if={@question} title="Ask for 6 more months" id="ask">
        <p class="mb-3 text-ink-soft">
          Answer one question and Tab adds 6 more months of Plus, with reading. No card, and it
          never turns into a paid plan by itself.
        </p>
        <.form for={@ask_form} id="ask_form" phx-submit="ask" class="space-y-3">
          <.input field={@ask_form[:answer]} type="textarea" label={@question} required />
          <.input
            field={@ask_form[:may_quote]}
            type="checkbox"
            label="Tab may quote what I wrote (it will say I got free months)"
          />
          <.button>Send</.button>
        </.form>
      </.card>

      <.card :if={@waiting?} id="waiting">
        <p>You asked for more time. You'll get an email when it's added.</p>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Billing.cloud?() do
      {:ok, socket |> assign(page_title: "Your plan") |> load()}
    else
      raise TabWeb.GroupData.NotFound
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    user_id = scope.user.id
    plan = Billing.plan(user_id)
    account = Tab.Repo.get(Account, user_id)
    paddle = Application.get_env(:tab, :paddle, [])
    today = Date.utc_today()

    checkout =
      if paddle[:client_token] && paddle[:plus_price_id],
        do: %{
          environment: paddle[:env],
          token: paddle[:client_token],
          price: paddle[:plus_price_id]
        }

    assign(socket,
      plan: plan,
      allowance: Billing.allowance(plan),
      used: Billing.reads_this_month(user_id),
      resumes_on: today |> Date.beginning_of_month() |> Date.shift(month: 1),
      checkout: checkout,
      customer?: match?(%Account{paddle_customer_id: c} when is_binary(c), account),
      question: Billing.extension_question(scope),
      waiting?: Billing.request_waiting?(scope),
      ask_form: to_form(%{"answer" => "", "may_quote" => false})
    )
  end

  @impl true
  def handle_event("ask", params, socket) do
    case Billing.request_extension(socket.assigns.current_scope, params) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Sent. Thanks for writing.") |> load()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Write an answer first.")}

      {:error, _} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("portal", _params, socket) do
    account = Tab.Repo.get(Account, socket.assigns.current_scope.user.id)

    case Paddle.portal_url(account && account.paddle_customer_id) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "Paddle's billing page didn't open. Try again in a minute.")}
    end
  end

  # Paddle tells the browser first; the webhook updates the plan a moment later.
  def handle_event("paid", _params, socket) do
    Process.send_after(self(), :reload, 4_000)
    {:noreply, put_flash(socket, :info, "Thanks! Your plan updates in a moment.")}
  end

  @impl true
  def handle_info(:reload, socket), do: {:noreply, load(socket)}

  defp plan_line(%{tier: :plus, source: :paid, until: until}),
    do: "Plus, paid through #{format_date(until)}."

  defp plan_line(%{tier: :pro, source: :paid, until: until}),
    do: "Pro, paid through #{format_date(until)}."

  defp plan_line(%{source: :trial, until: until}) do
    days = max(DateTime.diff(until, DateTime.utc_now(), :day), 0)

    "Trial Plus, #{days} #{if days == 1, do: "day", else: "days"} left (until #{format_date(until)})."
  end

  defp plan_line(%{tier: :free}),
    do: "Hosted free: everything in Tab except bill reading."
end
