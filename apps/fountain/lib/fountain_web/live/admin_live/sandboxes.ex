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

  defp assign_sandboxes(socket) do
    socket
    |> assign(:sandboxes, Conversations._unsafe_list_sandboxes_admin())
    |> assign(:provider_spend, Billing.provider_spend())
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

        <div :if={@sandboxes == []} class="text-sm text-zinc-500">No active sandboxes.</div>

        <table
          :if={@sandboxes != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200 font-mono"
        >
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
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
            <tr :for={s <- @sandboxes} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-2 text-xs">{String.slice(s.id, 0, 8)}</td>
              <td class="px-4 py-2 text-xs">
                <.link
                  :if={s.user}
                  navigate={~p"/admin/users/#{s.user.id}"}
                  class="hover:underline"
                >
                  {s.user.email}
                </.link>
                <span :if={is_nil(s.user)} class="text-zinc-400">—</span>
              </td>
              <td class="px-4 py-2">
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                  sandbox_status_color(s.status)
                ]}>
                  {s.status}
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">
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
              <td class="px-4 py-2 text-xs text-zinc-500">{format_ts(s.inserted_at)}</td>
              <td class="px-4 py-2 text-right space-x-2">
                <button
                  :if={
                    s.mode == "persistent" and s.status in ["ready", "suspended"] and
                      not is_nil(s.reset_requested_at)
                  }
                  phx-click="retry_reset"
                  phx-value-id={s.id}
                  data-confirm="Check the provider and retry deletion? Capacity stays reserved until the provider confirms the machine is gone."
                  class="text-xs text-blue-600 hover:text-blue-800 underline"
                >
                  Retry reset
                </button>
                <button
                  phx-click="reap_sandbox"
                  phx-value-id={s.id}
                  data-confirm={"Reap sandbox #{String.slice(s.id, 0, 8)}? Live conversations are terminated; idle ones stay resumable on a fresh sandbox."}
                  class="text-xs text-red-600 hover:text-red-800 underline"
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
        <p class="text-xs text-zinc-500">
          Active sandbox time {Calendar.strftime(@provider_spend.period_start, "%b %-d")} – now,
          parked time excluded. Minutes on different providers cost different amounts — hold these
          next to the invoice, they are not money.
          <.link :if={@credits_enabled} navigate={~p"/admin/finance"} class="underline">
            Finance prices them ↗
          </.link>
        </p>

        <div :if={@provider_spend.by_provider == %{}} class="text-xs text-zinc-400">
          No sandbox time this month.
        </div>

        <div :if={@provider_spend.by_provider != %{}} class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div
            :for={{provider, totals} <- Enum.sort(@provider_spend.by_provider)}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3"
          >
            <div class="text-xs text-zinc-500">{provider}</div>
            <div class="text-2xl font-semibold tabular-nums">
              {format_hours(SandboxUsage.hours(totals.active_seconds))}
            </div>
            <div class="text-xs text-zinc-500 tabular-nums">
              {totals.sandboxes} sandboxes · {totals.users} {if totals.users == 1,
                do: "tenant",
                else: "tenants"}
            </div>
            <div
              class="text-xs tabular-nums"
              title="No turn in flight. A shorter idle timeout removes this."
            >
              <span class={
                if idle_share(totals) >= 0.5, do: "text-amber-600 font-medium", else: "text-zinc-500"
              }>
                {format_hours(SandboxUsage.hours(totals.idle_seconds))} idle
              </span>
              <span class="text-zinc-400">({round(idle_share(totals) * 100)}%)</span>
            </div>
            <div :if={not SandboxUsage.platform_cost?(provider)} class="text-xs text-zinc-400">
              tenant hardware, not our bill
            </div>
          </div>
        </div>

        <div class="text-xs text-zinc-500 tabular-nums">
          Billable to us: {format_hours(SandboxUsage.hours(@provider_spend.platform_seconds))}
          <span :if={@provider_spend.platform_seconds > 0} class="text-zinc-400">
            · {format_hours(SandboxUsage.hours(@provider_spend.platform_idle_seconds))} of it idle,
            which is what a shorter idle timeout would remove
          </span>
        </div>

        <div
          :if={@provider_spend.top_tenants != []}
          class="bg-white rounded shadow border border-zinc-200"
        >
          <div class="px-4 py-2 text-xs font-medium text-zinc-500 border-b border-zinc-200">
            Who it belongs to
          </div>
          <ul class="divide-y divide-zinc-100">
            <li
              :for={tenant <- @provider_spend.top_tenants}
              class="px-4 py-2 text-xs flex items-center justify-between gap-3"
            >
              <span class="truncate">
                {tenant.email || "(deleted account)"}
                <span class="text-zinc-400">· {tenant.provider}</span>
              </span>
              <span class="tabular-nums whitespace-nowrap text-zinc-500">
                {format_hours(SandboxUsage.hours(tenant.active_seconds))}
                <span class="text-zinc-400">
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
