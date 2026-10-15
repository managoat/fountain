defmodule FountainWeb.CoreComponents do
  @moduledoc """
  Fountain design-system component library.

  All components reference CSS custom properties defined in
  `priv/static/assets/tokens.css`, extended into Tailwind utilities by the CDN
  config in `layouts/root.html.heex`. Dark mode flips automatically when
  `data-theme="dark"` is set on `<html>`.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # ────────────────────────────────────────────────────────────────────────────
  # button/1
  # Variants: primary (default), secondary, danger, ghost
  # Loading state: renders a spinner and disables the button.
  # ────────────────────────────────────────────────────────────────────────────

  attr :type, :string, default: "button"
  attr :variant, :string, default: "primary", values: ~w(primary secondary danger ghost)
  attr :loading, :boolean, default: false
  attr :class, :string, default: ""

  attr :rest, :global,
    include: ~w(disabled form name value phx-click phx-disable-with phx-value-id data-confirm)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@loading}
      class={[
        "inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium",
        "transition-colors focus-visible:outline-none focus-visible:ring-2",
        "focus-visible:ring-[var(--color-focus-ring)] focus-visible:ring-offset-1",
        "disabled:opacity-50 disabled:cursor-not-allowed",
        button_variant_class(@variant),
        @class
      ]}
      {@rest}
    >
      <svg
        :if={@loading}
        class="animate-spin size-3.5 shrink-0"
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        aria-hidden="true"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path
          class="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
        />
      </svg>
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_variant_class("primary"),
    do:
      "bg-[var(--color-brand)] text-[var(--color-brand-text)] hover:bg-[var(--color-brand-hover)]"

  defp button_variant_class("secondary"),
    do:
      "bg-[var(--color-bg-2)] text-[var(--color-text-primary)] hover:bg-[var(--color-bg-3)] border border-[var(--color-border)]"

  defp button_variant_class("danger"),
    do: "bg-[var(--color-error)] text-white hover:opacity-90"

  defp button_variant_class("ghost"),
    do:
      "bg-transparent text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)]"

  # ────────────────────────────────────────────────────────────────────────────
  # badge/1
  # Renders both status vocabularies (#401 — the old comment labelled the
  # sandbox set as the conversation one, which is how `idle` got left out):
  #   conversation: pending | running | idle | failed | terminated
  #   sandbox:      pending | starting | running | ready | terminated | failed
  # ────────────────────────────────────────────────────────────────────────────

  attr :status, :string, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded px-2 py-0.5 text-xs font-medium",
      badge_bg_class(@status)
    ]}>
      <span class={["size-1.5 rounded-full shrink-0", badge_dot_class(@status)]}></span>
      {@status}
    </span>
    """
  end

  defp badge_bg_class("pending"),
    do: "bg-[var(--status-pending-bg)] text-[var(--status-pending-text)]"

  defp badge_bg_class("starting"),
    do: "bg-[var(--status-starting-bg)] text-[var(--status-starting-text)]"

  defp badge_bg_class("running"),
    do: "bg-[var(--status-starting-bg)] text-[var(--status-starting-text)]"

  defp badge_bg_class("ready"),
    do: "bg-[var(--status-ready-bg)] text-[var(--status-ready-text)]"

  # The resting state of every healthy conversation between turns — green,
  # not the unrecognised-value grey it fell into before (#401).
  defp badge_bg_class("idle"),
    do: "bg-[var(--status-ready-bg)] text-[var(--status-ready-text)]"

  defp badge_bg_class("terminated"),
    do: "bg-[var(--status-terminated-bg)] text-[var(--status-terminated-text)]"

  defp badge_bg_class("failed"),
    do: "bg-[var(--status-failed-bg)] text-[var(--status-failed-text)]"

  defp badge_bg_class(_),
    do: "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)]"

  defp badge_dot_class("starting"), do: "bg-[var(--status-starting-text)] animate-pulse"
  defp badge_dot_class("running"), do: "bg-[var(--status-starting-text)] animate-pulse"
  defp badge_dot_class("pending"), do: "bg-[var(--status-pending-text)]"
  defp badge_dot_class("ready"), do: "bg-[var(--status-ready-text)]"
  defp badge_dot_class("idle"), do: "bg-[var(--status-ready-text)]"
  defp badge_dot_class("terminated"), do: "bg-[var(--status-terminated-text)]"
  defp badge_dot_class("failed"), do: "bg-[var(--status-failed-text)]"
  defp badge_dot_class(_), do: "bg-[var(--color-text-muted)]"

  # ────────────────────────────────────────────────────────────────────────────
  # label_chips/1 (#1637)
  #
  # A conversation's labels, as small `key=value` chips. Sorted by key, so a
  # row reads the same on every render. Renders nothing at all when there are
  # none — an empty row of chips is noise on a list where most conversations
  # carry no labels.
  #
  # `href` makes each chip a link to the same list filtered by that one label.
  # Give it a function of `{key, value}`; leave it nil for a read-only list.
  # ────────────────────────────────────────────────────────────────────────────

  attr :labels, :map, default: %{}
  attr :href, :any, default: nil

  def label_chips(assigns) do
    assigns = assign(assigns, :sorted, Enum.sort_by(assigns.labels || %{}, &elem(&1, 0)))

    ~H"""
    <span :if={@sorted != []} class="inline-flex flex-wrap gap-1 align-middle">
      <.link
        :for={{key, value} <- @sorted}
        :if={@href}
        patch={@href.({key, value})}
        class="rounded bg-[var(--color-bg-2)] px-1.5 py-0.5 font-mono text-[11px] text-[var(--color-text-secondary)] hover:text-[var(--color-text)]"
        data-label-chip={key}
      >
        {key}={value}
      </.link>
      <span
        :for={{key, value} <- @sorted}
        :if={is_nil(@href)}
        class="rounded bg-[var(--color-bg-2)] px-1.5 py-0.5 font-mono text-[11px] text-[var(--color-text-secondary)]"
        data-label-chip={key}
      >
        {key}={value}
      </span>
    </span>
    """
  end

  # ────────────────────────────────────────────────────────────────────────────
  # flash/1
  # Kinds: :info, :success, :warning, :error
  # Auto-dismisses after 5 s via the AutoDismiss JS hook.
  # ────────────────────────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :kind, :atom, default: :info, values: [:info, :success, :warning, :error]
  attr :rest, :global
  slot :inner_block, required: true

  def flash(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="AutoDismiss"
      role="alert"
      class={[
        "flex items-start gap-3 rounded-lg border px-4 py-3 text-sm shadow-sm",
        flash_class(@kind)
      ]}
      {@rest}
    >
      <svg
        class="mt-0.5 size-4 shrink-0"
        viewBox="0 0 20 20"
        fill="currentColor"
        aria-hidden="true"
      >
        {Phoenix.HTML.raw(flash_icon(@kind))}
      </svg>
      <span class="flex-1">{render_slot(@inner_block)}</span>
      <button
        phx-click={JS.hide(to: "##{@id}")}
        type="button"
        aria-label="Dismiss"
        class="shrink-0 rounded p-0.5 opacity-60 hover:opacity-100 transition-opacity focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-focus-ring)]"
      >
        <svg class="size-3.5" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
          <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
        </svg>
      </button>
    </div>
    """
  end

  defp flash_class(:info),
    do: "bg-[var(--color-info-bg)] border-[var(--color-info)] text-[var(--color-info-text)]"

  defp flash_class(:success),
    do:
      "bg-[var(--color-success-bg)] border-[var(--color-success)] text-[var(--color-success-text)]"

  defp flash_class(:warning),
    do:
      "bg-[var(--color-warning-bg)] border-[var(--color-warning)] text-[var(--color-warning-text)]"

  defp flash_class(:error),
    do: "bg-[var(--color-error-bg)] border-[var(--color-error)] text-[var(--color-error-text)]"

  defp flash_icon(:info),
    do:
      ~s(<path fill-rule="evenodd" d="M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0Zm-7-4a1 1 0 1 1-2 0 1 1 0 0 1 2 0ZM9 9a.75.75 0 0 0 0 1.5h.253a.25.25 0 0 1 .244.304l-.459 2.066A1.75 1.75 0 0 0 10.747 15H11a.75.75 0 0 0 0-1.5h-.253a.25.25 0 0 1-.244-.304l.459-2.066A1.75 1.75 0 0 0 9.253 9H9Z" clip-rule="evenodd"/>)

  defp flash_icon(:success),
    do:
      ~s(<path fill-rule="evenodd" d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm3.857-9.809a.75.75 0 0 0-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 1 0-1.06 1.061l2.5 2.5a.75.75 0 0 0 1.137-.089l4-5.5Z" clip-rule="evenodd"/>)

  defp flash_icon(:warning),
    do:
      ~s(<path fill-rule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495ZM10 5a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 5Zm0 9a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z" clip-rule="evenodd"/>)

  defp flash_icon(:error),
    do:
      ~s(<path fill-rule="evenodd" d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16ZM8.28 7.22a.75.75 0 0 0-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 1 0 1.06 1.06L10 11.06l1.72 1.72a.75.75 0 1 0 1.06-1.06L11.06 10l1.72-1.72a.75.75 0 0 0-1.06-1.06L10 8.94 8.28 7.22Z" clip-rule="evenodd"/>)

  attr :flash, :map, default: %{}

  def flash_group(assigns) do
    ~H"""
    <div
      class="fixed top-4 right-4 z-50 space-y-2 w-80 max-w-[calc(100vw-2rem)]"
      aria-live="polite"
    >
      <.flash :if={Phoenix.Flash.get(@flash, :info)} kind={:info} id="flash-info">
        {Phoenix.Flash.get(@flash, :info)}
      </.flash>
      <.flash :if={Phoenix.Flash.get(@flash, :error)} kind={:error} id="flash-error">
        {Phoenix.Flash.get(@flash, :error)}
      </.flash>
    </div>
    """
  end

  # ────────────────────────────────────────────────────────────────────────────
  # form_field/1
  # Wraps label + input/textarea + inline error messages.
  # ────────────────────────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :value, :any, default: ""
  attr :placeholder, :string, default: nil
  attr :errors, :list, default: []
  attr :hint, :string, default: nil
  attr :class, :string, default: ""

  attr :rest, :global,
    include: ~w(autofocus required disabled readonly rows cols min max step pattern phx-hook list)

  def form_field(assigns) do
    ~H"""
    <div class={["space-y-1", @class]}>
      <label
        :if={@label}
        for={@id}
        class="block text-sm font-medium text-[var(--color-text-primary)]"
      >
        {@label}
      </label>
      <textarea
        :if={@type == "textarea"}
        id={@id}
        name={@name}
        placeholder={@placeholder}
        class={[
          "block w-full rounded-md border px-3 py-2 text-sm",
          "bg-[var(--color-bg-1)] text-[var(--color-text-primary)]",
          "placeholder:text-[var(--color-text-muted)]",
          "focus:outline-none focus:ring-2 focus:ring-[var(--color-focus-ring)] focus:border-transparent",
          "disabled:opacity-50 disabled:cursor-not-allowed",
          if(@errors == [], do: "border-[var(--color-border)]", else: "border-[var(--color-error)]")
        ]}
        {@rest}
      >{@value}</textarea>
      <input
        :if={@type not in ["textarea"]}
        type={@type}
        id={@id}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class={[
          "block w-full rounded-md border px-3 py-2 text-sm",
          "bg-[var(--color-bg-1)] text-[var(--color-text-primary)]",
          "placeholder:text-[var(--color-text-muted)]",
          "focus:outline-none focus:ring-2 focus:ring-[var(--color-focus-ring)] focus:border-transparent",
          "disabled:opacity-50 disabled:cursor-not-allowed",
          if(@errors == [], do: "border-[var(--color-border)]", else: "border-[var(--color-error)]")
        ]}
        {@rest}
      />
      <p :if={@hint && @errors == []} class="text-xs text-[var(--color-text-muted)]">{@hint}</p>
      <p :for={error <- @errors} class="text-xs text-[var(--color-error)]" role="alert">
        {error}
      </p>
    </div>
    """
  end
end
