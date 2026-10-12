defmodule TabWeb.CoreComponents do
  @moduledoc """
  Tab's building blocks, styled with the b28 clay kit (`assets/vendor/b28-clay.css`)
  and the Tailwind names `assets/css/app.css` gives its tokens: `bg-raised`,
  `text-ink-soft`, `shadow-well`, `font-display`, and so on. There's no other
  palette: colors come from the kit, plus `warn` for errors.

  Icons are [Heroicons](https://heroicons.com), see `icon/1`.
  """
  use Phoenix.Component
  use Gettext, backend: TabWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed inset-x-4 top-4 z-50 sm:left-auto sm:w-96"
      {@rest}
    >
      <div class={[
        "clay-surface flex items-start gap-3 p-4",
        @kind == :error && "border-l-4 border-warn"
      ]}>
        <.icon :if={@kind == :info} name="hero-check-circle" class="size-5 shrink-0 text-primary" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0 text-warn" />
        <div class="flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <button type="button" class="group cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a pressable clay button, or a link that looks like one.

      <.button>Save</.button>
      <.button variant="soft" navigate={~p"/groups"}>Back</.button>
      <.button variant="warn" phx-click="delete">Delete</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form)

  attr :class, :any, default: nil
  attr :variant, :string, default: "primary", values: ~w(primary soft warn)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [
        "clay-button text-center",
        assigns.variant == "soft" && "clay-button--soft",
        assigns.variant == "warn" && "clay-button--warn",
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  Pass a `Phoenix.HTML.FormField` as `field`, or every attribute by hand.
  `type="select"` renders a `<select>` (pass `options`, and optionally
  `prompt`); `type="checkbox"` is for booleans. Radios are written in templates.

      <.input field={@form[:email]} type="email" label="Email" />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil, doc: "a short line under the label"
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "extra classes for the control"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form inputmode list max maxlength min
                minlength multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-3">
      <label class="flex items-center gap-3">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={["tab-check", @class]}
          {@rest}
        />
        <span>{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id} class="block">
        <.label label={@label} hint={@hint} />
        <select
          id={@id}
          name={@name}
          class={["tab-field", @class]}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id} class="block">
        <.label label={@label} hint={@hint} />
        <textarea
          id={@id}
          name={@name}
          class={["tab-field min-h-24", @class]}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id} class="block">
        <.label label={@label} hint={@hint} />
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={["tab-field", @class]}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  attr :label, :string, default: nil
  attr :hint, :string, default: nil

  defp label(assigns) do
    ~H"""
    <span :if={@label} class="mb-1.5 block font-semibold">{@label}</span>
    <span :if={@hint} class="-mt-1 mb-1.5 block text-sm text-ink-soft">{@hint}</span>
    """
  end

  @doc "Shows a form error."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm text-warn">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "A page header: the title, an optional line under it, and actions on the right."
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex flex-wrap items-end justify-between gap-4", "pb-6"]}>
      <div>
        <h1 class="text-3xl leading-tight font-semibold">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-ink-soft">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "A raised clay panel with an optional heading."
  attr :title, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :actions

  def card(assigns) do
    ~H"""
    <section id={@id} class={["clay-surface p-5 sm:p-6", @class]}>
      <div
        :if={@title || @actions != []}
        class="mb-4 flex flex-wrap items-center justify-between gap-2"
      >
        <h2 :if={@title} class="text-xl font-semibold">{@title}</h2>
        <div :if={@actions != []} class="flex flex-wrap gap-2">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  An amount of money, from whole cents, in the instance's currency.

      <.money cents={1250} />  → $12.50
  """
  attr :cents, :integer, required: true
  attr :class, :any, default: nil

  def money(assigns) do
    ~H"""
    <span class={["money", @class]}>{TabWeb.Format.money(@cents)}</span>
    """
  end

  @doc "A link back to the previous page."
  attr :navigate, :any, required: true
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="mb-4 inline-flex items-center gap-1 text-ink-soft hover:text-ink"
    >
      <.icon name="hero-arrow-left" class="size-4" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Renders a table, used by the generated pages that still need one.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="w-full text-left">
      <thead class="text-sm text-ink-soft">
        <tr>
          <th :for={col <- @col} class="pb-2 font-semibold">{col[:label]}</th>
          <th :if={@action != []}><span class="sr-only">{gettext("Actions")}</span></th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="border-t border-line">
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={["py-2", @row_click && "hover:cursor-pointer"]}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 py-2 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

      <.list>
        <:item title="Paid by">{@payer}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="divide-y divide-line">
      <div :for={item <- @item} class="flex justify-between gap-4 py-2">
        <dt class="text-ink-soft">{item.title}</dt>
        <dd class="text-right">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(TabWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(TabWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
