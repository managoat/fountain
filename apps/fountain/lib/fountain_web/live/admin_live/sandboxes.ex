defmodule FountainWeb.AdminLive.Sandboxes do
  @moduledoc """
  `/admin/sandboxes` — what is running right now, and what running it has cost
  this month.

  The two halves belong together: the live list says which boxes are up, and
  the spend panel says which provider they are up on and how much of that time
  had no turn in flight. Idle time is the lever on the provider bill, and the
  only way to act on it is to look at a running sandbox.

  The spend panel is deliberately not gated on billing being enabled. A
  self-hosted deployment still pays a provider, and this is the only page that
  says whose sandboxes the bill is for. What it does *not* do is put money on
  the screen — minutes on different providers cost different amounts, and the
  rate card lives on `/admin/finance`.
  """

  use FountainWeb, :live_view

  require Logger

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.{Accounts, Billing, Conversations}
  alias Fountain.Billing.SandboxUsage
  alias Fountain.Conversations.Termination
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Sandboxes")
     |> assign(:credits_enabled, Fountain.Credits.enabled?())
     |> assign_sandboxes()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 10_000)
    {:noreply, assign_sandboxes(socket)}
  end

  @impl true
  def handle_event("reap_sandbox", %{"id" => id}, socket) do
    # Termination.reap_sandbox/2 records admin.sandbox.reaped itself (#2255
    # decision 4).
    case Termination.reap_sandbox(id, admin_user_id: socket.assigns.current_user.id) do
      {:ok, outcome} ->
        msg =
          case outcome do
            :terminated -> "Sandbox and its live conversations terminated"
            :released -> "Sandbox released — conversations stay resumable"
            :already_terminal -> "Sandbox was already terminated"
          end

        {:noreply, socket |> assign_sandboxes() |> put_flash(:info, msg)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Sandbox not found")}

      # Since ADR 0058 stage 5b a reap can be refused: the machine's owner is
      # already destroying it, most often the reaper's own expiry of the same
      # row. A flash, not a crash — the operator's next click is the whole
      # remedy, and the row is refreshed so they can see whether the other
      # teardown finished it in the meantime.
      {:error, reason} ->
        Logger.warning("admin reap of sandbox #{id} refused: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign_sandboxes()
         |> put_flash(:error, "Sandbox busy — another teardown is running; try again")}
    end
  end

  def handle_event("retry_reset", %{"id" => id}, socket) do
    case current_admin(socket) do
      {:ok, socket} -> retry_reset(socket, id)
      {:error, socket} -> {:noreply, socket}
    end
  end

  # An open tab can outlive an admin role, verification or login session.
  # Recheck before the unscoped sandbox fetch and any provider action.
  defp current_admin(socket) do
    mounted = socket.assigns.current_user
    user = Accounts.get_user(mounted.id)

    cond do
      is_nil(user) or user.session_version != mounted.session_version or
          not is_nil(user.suspended_at) ->
        {:error, redirect(socket, to: ~p"/auth/login")}

      is_nil(user.email_verified_at) ->
        {:error, redirect(socket, to: ~p"/auth/verify-pending")}

      user.role != "admin" ->
        {:error, push_navigate(socket, to: ~p"/dashboard")}

      true ->
        {:ok, assign(socket, :current_user, user)}
    end
  end

  defp retry_reset(socket, id) do
    # Ownership: the current_admin check above authorizes this operator's
    # unscoped lookup. Invalid or vanished IDs never reach a provider.
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Conversations.Sandbox{} = sandbox <- Conversations._unsafe_get_sandbox(id) do
      result =
        Conversations.retry_pending_sandbox_reset(sandbox,
          reprobe: true,
          actor: "admin",
          by: "admin",
          reason: "reset_reconciled"
        )

      {kind, outcome, message} = reset_result(result)

      Fountain.Audit.record_admin(%{
        actor_user_id: socket.assigns.current_user.id,
        target_user_id: sandbox.user_id,
        event_type: "admin.sandbox.reset_retried",
        metadata: %{"sandbox_id" => id, "outcome" => outcome}
      })

      {:noreply, socket |> assign_sandboxes() |> put_flash(kind, message)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Sandbox not found")}
    end
  end

  defp reset_result({:ok, :skipped}),
    do: {:info, "skipped", "Sandbox no longer has a pending reset"}

  defp reset_result({:ok, %Conversations.Sandbox{}}),
    do: {:info, "completed", "Provider confirmed deletion; sandbox capacity released"}

  defp reset_result({:error, :not_found}),
    do: {:error, "not_found", "Sandbox not found"}

  # Not the same answer as an unconfirmed deletion, and an operator acts on the
  # difference: another teardown of this machine is running (ADR 0058), so the
  # fence is being dealt with rather than stuck, and clicking again in a moment
  # is the right move. Same wording as the reap's refusal above.
  defp reset_result({:error, :sandbox_unavailable}),
    do: {:error, "busy", "Sandbox busy — another teardown is running; try again"}

  defp reset_result({:error, _}),
    do:
      {:error, "pending",
       "Deletion is still unconfirmed; reset fence and capacity remain reserved"}

  # What a stamp means, and it depends on the lease first (ADR 0058 stage 9a).
  #
  # **The lease question is asked before anything else**, because a live lease
  # means an owner is working on this machine right now whatever the stamp says
  # — the amber badge beside this note says exactly that, and a row that
  # rendered "an owner is working" next to a word meaning "nobody is" would be
  # the page contradicting itself. `admin_sandboxes_live_test.exs` has pinned
  # that rule for `parking` since 6b; the first draft of this function skipped
  # it for `destroying` and broke it (surfaces review, S2).
  #
  # With no live lease the two cases genuinely differ. `parking`, `resuming`,
  # `provisioning` and `retargeting` are operations whose owner died: abandoned,
  # and the next owner to claim the machine clears them. `destroying` is durable
  # intent that outlived its owner — nothing clears it and the machine is still
  # on its way out — so "abandoned" would tell an operator the opposite of both
  # what the row means and what the Reap button will do.
  #
  # Deliberately one word for both kinds of unfinished destroy, because the
  # operator's question is "is this machine going away", not "which worker will
  # finish it". A forced teardown is finished by
  # `SandboxReaper.sweep_fenced_teardowns/0`; a *reset* is not — that sweep
  # skips reason `"reset"` — and `SandboxResetReconciler` finishes it instead,
  # with a Retry reset button on this same row.
  @doc false
  # Public so `admin_sandboxes_live_test.exs` can drive the rule directly. The
  # page-level assertion for it could only match strings over the whole
  # rendered document, which reads every other row in the table as well.
  def lease_less_note(sandbox, lease_now) do
    cond do
      Machine.busy?(sandbox, lease_now) -> ""
      sandbox.transition == "destroying" -> " (unfinished)"
      true -> " (abandoned)"
    end
  end

  defp assign_sandboxes(socket) do
    socket
    |> assign(:sandboxes, Conversations._unsafe_list_sandboxes_admin())
    |> assign(:provider_spend, Billing.provider_spend())
    # One clock for the whole table (ADR 0058 stage 7a): `Machine.busy?/2`
    # judges against the database's `now()`, and letting each of two calls per
    # row fetch its own would be two queries a row on a page that refreshes
    # every ten seconds. Judging every row against one instant is also the
    # honest reading — the table is one snapshot.
    |> assign(:lease_now, Lease.now())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Sandboxes" current={:sandboxes} credits_enabled={@credits_enabled}>
        <:subtitle>
          {length(@sandboxes)} active. Refreshes every 10s.
        </:subtitle>
      </.admin_header>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Active sandboxes</h2>

        <div :if={@sandboxes == []} class="text-sm text-[var(--color-text-secondary)]">
          No active sandboxes.
        </div>

        <table
          :if={@sandboxes != []}
          class="w-full text-sm bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] font-mono"
        >
          <thead class="text-left text-[var(--color-text-secondary)] border-b border-[var(--color-border)]">
            <tr>
              <th class="px-4 py-2">ID</th>
              <th class="px-4 py-2">Owner</th>
              <th class="px-4 py-2">Status</th>
              <th class="px-4 py-2">Conversations</th>
              <th class="px-4 py-2">Started</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @sandboxes} class="border-b border-[var(--color-border)] last:border-0">
              <td class="px-4 py-2 text-xs">{String.slice(s.id, 0, 8)}</td>
              <td class="px-4 py-2 text-xs">
                <.link
                  :if={s.user}
                  navigate={~p"/admin/users/#{s.user.id}"}
                  class="hover:underline"
                >
                  {s.user.email}
                </.link>
                <span :if={is_nil(s.user)} class="text-[var(--color-text-muted)]">—</span>
              </td>
              <td class="px-4 py-2">
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                  sandbox_status_color(s.status)
                ]}>
                  {s.status}
                </span>
                <%!-- What the machine's owner is doing to it right now (ADR 0058).
                      Without this the page says `ready` for a machine being parked
                      or destroyed, which is the reading an operator makes a decision
                      on — and the reason that decision's Reap button answers 503. --%>
                <span
                  :if={s.transition}
                  title={"#{s.transition}#{if s.transition_reason, do: " (#{s.transition_reason})"}"}
                  class={[
                    "ml-1 inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                    if(Machine.busy?(s, @lease_now),
                      do: "border-amber-200 bg-amber-50 text-amber-700",
                      else: "border-zinc-200 bg-zinc-50 text-zinc-500"
                    )
                  ]}
                >
                  {s.transition}{lease_less_note(s, @lease_now)}
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-[var(--color-text-secondary)]">
                <span :if={s.conversations == []}>—</span>
                <span :if={s.conversations != []} class="space-x-2">
                  <.link
                    :for={c <- s.conversations}
                    navigate={~p"/admin/conversations/#{c.id}"}
                    class="hover:underline"
                  >
                    {String.slice(c.id, 0, 8)}
                  </.link>
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-[var(--color-text-secondary)]">
                {format_ts(s.inserted_at)}
              </td>
              <td class="px-4 py-2 text-right space-x-2">
                <button
                  :if={
                    s.mode == "persistent" and s.status in ["ready", "suspended"] and
                      not is_nil(s.reset_requested_at)
                  }
                  phx-click="retry_reset"
                  phx-value-id={s.id}
                  data-confirm="Check the provider and retry deletion? Capacity stays reserved until the provider confirms the machine is gone."
                  class="text-xs text-[var(--color-info-text)] hover:text-[var(--color-info)] underline"
                >
                  Retry reset
                </button>
                <button
                  phx-click="reap_sandbox"
                  phx-value-id={s.id}
                  data-confirm={"Reap sandbox #{String.slice(s.id, 0, 8)}? Live conversations are terminated; idle ones stay resumable on a fresh sandbox."}
                  class="text-xs text-[var(--color-error-text)] hover:text-[var(--color-error)] underline"
                >
                  Reap
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Spend by provider</h2>
        <p class="text-xs text-[var(--color-text-secondary)]">
          Active sandbox time {Calendar.strftime(@provider_spend.period_start, "%b %-d")} – now,
          parked time excluded. Minutes on different providers cost different amounts — hold these
          next to the invoice, they are not money.
          <.link :if={@credits_enabled} navigate={~p"/admin/finance"} class="underline">
            Finance prices them ↗
          </.link>
        </p>

        <div :if={@provider_spend.by_provider == %{}} class="text-xs text-[var(--color-text-muted)]">
          No sandbox time this month.
        </div>

        <div :if={@provider_spend.by_provider != %{}} class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div
            :for={{provider, totals} <- Enum.sort(@provider_spend.by_provider)}
            class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3"
          >
            <div class="text-xs text-[var(--color-text-secondary)]">{provider}</div>
            <div class="text-2xl font-semibold tabular-nums">
              {format_hours(SandboxUsage.hours(totals.active_seconds))}
            </div>
            <div class="text-xs text-[var(--color-text-secondary)] tabular-nums">
              {totals.sandboxes} sandboxes · {totals.users} {if totals.users == 1,
                do: "tenant",
                else: "tenants"}
            </div>
            <div
              class="text-xs tabular-nums"
              title="No turn in flight. A shorter idle timeout removes this."
            >
              <span class={
                if idle_share(totals) >= 0.5,
                  do: "text-[var(--color-warning-text)] font-medium",
                  else: "text-[var(--color-text-secondary)]"
              }>
                {format_hours(SandboxUsage.hours(totals.idle_seconds))} idle
              </span>
              <span class="text-[var(--color-text-muted)]">({round(idle_share(totals) * 100)}%)</span>
            </div>
            <div
              :if={not SandboxUsage.platform_cost?(provider)}
              class="text-xs text-[var(--color-text-muted)]"
            >
              tenant hardware, not our bill
            </div>
          </div>
        </div>

        <div class="text-xs text-[var(--color-text-secondary)] tabular-nums">
          Billable to us: {format_hours(SandboxUsage.hours(@provider_spend.platform_seconds))}
          <span :if={@provider_spend.platform_seconds > 0} class="text-[var(--color-text-muted)]">
            · {format_hours(SandboxUsage.hours(@provider_spend.platform_idle_seconds))} of it idle,
            which is what a shorter idle timeout would remove
          </span>
        </div>

        <div
          :if={@provider_spend.top_tenants != []}
          class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)]"
        >
          <div class="px-4 py-2 text-xs font-medium text-[var(--color-text-secondary)] border-b border-[var(--color-border)]">
            Who it belongs to
          </div>
          <ul class="divide-y divide-[var(--color-border)]">
            <li
              :for={tenant <- @provider_spend.top_tenants}
              class="px-4 py-2 text-xs flex items-center justify-between gap-3"
            >
              <span class="truncate">
                {tenant.email || "(deleted account)"}
                <span class="text-[var(--color-text-muted)]">· {tenant.provider}</span>
              </span>
              <span class="tabular-nums whitespace-nowrap text-[var(--color-text-secondary)]">
                {format_hours(SandboxUsage.hours(tenant.active_seconds))}
                <span class="text-[var(--color-text-muted)]">
                  ({round(idle_share(tenant) * 100)}% idle)
                </span>
                · {tenant.sandboxes} sandboxes
              </span>
            </li>
          </ul>
        </div>
      </section>
    </div>
    """
  end
end
