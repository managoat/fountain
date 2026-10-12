defmodule FountainWeb.AdminLive.Index do
  @moduledoc """
  `/admin` — one tile per thing that could be wrong.

  This page used to be the whole admin panel: six stacked sections, and a
  `mount` plus a ten-second refresh that re-ran every query behind all six
  regardless of which one an operator had scrolled to. The sections are now
  `/admin/users`, `/admin/sandboxes`, `/admin/inference`, `/admin/broker` and
  `/admin/activity`,
  and what is left here is the glance: is anything on fire, and where do I go.

  Every tile is a link. A number on this page is never the place to act on
  that number — the levers live on the page the tile points at, next to their
  confirmations.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.Conversations
  alias Fountain.Machines.Usage, as: SandboxUsage

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
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
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Admin" current={:overview}>
        <:subtitle>System overview. Refreshes every 10s.</:subtitle>
      </.admin_header>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">At a glance</h2>
        <div class="grid grid-cols-2 sm:grid-cols-5 gap-3">
          <.link
            navigate={~p"/admin/sandboxes"}
            class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3 hover:border-[var(--color-border-strong)]"
          >
            <div class="text-xs text-[var(--color-text-secondary)]">Active sandboxes</div>
            <div class="text-2xl font-semibold tabular-nums">{@sandbox_count}</div>
            <div class="text-xs text-[var(--color-text-secondary)]">running now ↗</div>
          </.link>

          <%!-- Hours, not money: minutes on different providers cost
                different amounts. --%>
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
