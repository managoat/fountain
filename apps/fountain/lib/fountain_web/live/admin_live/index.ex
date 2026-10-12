defmodule FountainWeb.AdminLive.Index do
  @moduledoc """
  `/admin` — one tile per thing that could be wrong.

  This page used to be the whole admin panel: six stacked sections, and a
  `mount` plus a ten-second refresh that re-ran every query behind all six
  regardless of which one an operator had scrolled to. The sections are now
  `/admin/users`, `/admin/sandboxes`, `/admin/billing` and `/admin/activity`,
  and what is left here is the glance: is anything on fire, and where do I go.

  Every tile is a link. A number on this page is never the place to act on
  that number — the levers live on the page the tile points at, next to their
  confirmations.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.{Billing, Conversations}
  alias Fountain.Machines.Usage, as: SandboxUsage

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:credits_enabled, Fountain.Credits.enabled?())
     |> assign_overview()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 10_000)
    {:noreply, assign_overview(socket)}
  end

  defp assign_overview(socket) do
    socket
    |> assign(:provider_spend, SandboxUsage.provider_spend())
    |> assign(:sandbox_count, Conversations._unsafe_count_sandboxes_admin())
    # Whatever installed extensions report (ADR 0043). The console renders
    # numbers it is handed; it does not know what an extension is called or
    # what its figures mean, and `apps/fountain/lib` names no extension module.
    |> assign(:extension_overview, Fountain.Extensions.admin_overview())
    |> assign_billing_overview()
  end

  # overview_admin/0 runs real queries (funded accounts, deferred credit,
  # webhook events);
  # on a billing-disabled instance nothing renders them, so don't run them.
  defp assign_billing_overview(socket) do
    if socket.assigns.credits_enabled do
      assign(socket, :billing_overview, Billing.overview_admin())
    else
      assign(socket, :billing_overview, nil)
    end
  end

  # An extension's admin figure. `{label, value}` or `{label, value, opts}`,
  # where opts may carry :navigate (make the tile a link) and :note (a line
  # under the number). The host owns every element of the markup.
  attr :tile, :any, required: true

  defp extension_tile(assigns) do
    {label, value, opts} = normalize_tile(assigns.tile)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:value, value)
      |> assign(:navigate, Keyword.get(opts, :navigate))
      |> assign(:note, Keyword.get(opts, :note))

    ~H"""
    <.link
      :if={@navigate}
      navigate={@navigate}
      class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3 hover:border-[var(--color-border-strong)]"
    >
      <div class="text-xs text-[var(--color-text-secondary)]">{@label}</div>
      <div class="text-2xl font-semibold tabular-nums">{@value}</div>
      <div :if={@note} class="text-xs text-[var(--color-text-secondary)]">{@note}</div>
    </.link>
    <div
      :if={!@navigate}
      class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3"
    >
      <div class="text-xs text-[var(--color-text-secondary)]">{@label}</div>
      <div class="text-2xl font-semibold tabular-nums">{@value}</div>
      <div :if={@note} class="text-xs text-[var(--color-text-secondary)]">{@note}</div>
    </div>
    """
  end

  defp normalize_tile({label, value}), do: {label, value, []}
  defp normalize_tile({label, value, opts}) when is_list(opts), do: {label, value, opts}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Admin" current={:overview} credits_enabled={@credits_enabled}>
        <:subtitle>System overview. Refreshes every 10s.</:subtitle>
      </.admin_header>

      <%!-- The one genuinely bad state that has no tile of its own, because a
            count is not the point: which webhooks, and how long they have
            been failing, is on the billing page. --%>
      <.link
        :if={@credits_enabled and @billing_overview.failed_events != []}
        navigate={~p"/admin/finance"}
        class="block bg-red-50 border border-red-200 rounded px-4 py-3 text-sm text-red-900 hover:border-red-400"
      >
        <span class="font-medium">
          {length(@billing_overview.failed_events)} webhook {if length(
                                                                  @billing_overview.failed_events
                                                                ) == 1,
                                                                do: "event is",
                                                                else: "events are"} failing
        </span>
        — a purchase or a clawback may not have reached the ledger. See Billing ↗
      </.link>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">At a glance</h2>
        <div class="grid grid-cols-2 sm:grid-cols-5 gap-3">
          <.link
            :if={@credits_enabled}
            navigate={~p"/admin/finance"}
            class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3 hover:border-[var(--color-border-strong)]"
          >
            <div class="text-xs text-[var(--color-text-secondary)]">Deferred credit</div>
            <div class="text-2xl font-semibold tabular-nums">
              {Fountain.Credits.format_cents(@billing_overview.deferred_cents || 0)}
            </div>
            <div class="text-xs text-[var(--color-text-secondary)]">
              held by {@billing_overview.funded} funded accounts · finance ↗
            </div>
          </.link>

          <.link
            :if={@credits_enabled}
            navigate={~p"/admin/finance"}
            class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3 hover:border-[var(--color-border-strong)]"
          >
            <div class="text-xs text-[var(--color-text-secondary)]">Packs bought this month</div>
            <div class="text-2xl font-semibold tabular-nums">
              {@billing_overview.purchases_this_month}
            </div>
            <div class="text-xs text-[var(--color-text-secondary)]">
              {@billing_overview.comped} comped accounts ↗
            </div>
          </.link>

          <.link
            navigate={~p"/admin/sandboxes"}
            class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3 hover:border-[var(--color-border-strong)]"
          >
            <div class="text-xs text-[var(--color-text-secondary)]">Active sandboxes</div>
            <div class="text-2xl font-semibold tabular-nums">{@sandbox_count}</div>
            <div class="text-xs text-[var(--color-text-secondary)]">running now ↗</div>
          </.link>

          <%!-- Installed extensions' figures (ADR 0043). One tile each, in
                configured order, rendered from data the extension returns.
                Nothing here knows what an extension is; with none installed
                this renders nothing. --%>
          <.extension_tile :for={tile <- @extension_overview} tile={tile} />

          <%!-- Hours, not money: minutes on different providers cost
                different amounts, and only /admin/finance has the rate card
                that turns one into the other. --%>
          <.link
            navigate={~p"/admin/sandboxes"}
            class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3 hover:border-[var(--color-border-strong)]"
          >
            <div class="text-xs text-[var(--color-text-secondary)]">Billable sandbox time</div>
            <div class="text-2xl font-semibold tabular-nums">
              {format_hours(SandboxUsage.hours(@provider_spend.platform_seconds))}
            </div>
            <div class={[
              "text-xs tabular-nums",
              if(idle_share(platform_totals(@provider_spend)) >= 0.5,
                do: "text-[var(--color-warning-text)] font-medium",
                else: "text-[var(--color-text-secondary)]"
              )
            ]}>
              {format_hours(SandboxUsage.hours(@provider_spend.platform_idle_seconds))} idle ↗
            </div>
          </.link>
        </div>
      </section>
    </div>
    """
  end

  # `idle_share/1` reads the same shape a per-provider row has, so the
  # platform totals are put into that shape rather than the ratio recomputed.
  defp platform_totals(spend) do
    %{active_seconds: spend.platform_seconds, idle_seconds: spend.platform_idle_seconds}
  end
end
