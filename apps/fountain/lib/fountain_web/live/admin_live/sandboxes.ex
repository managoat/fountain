defmodule FountainWeb.AdminLive.Sandboxes do
  @moduledoc """
  `/admin/sandboxes` — what is running right now, and the lever to reap it.

  What running them cost is the provider's invoice; Fountain keeps no
  per-provider or per-account roll-up of sandbox time (ADR 0079).
  """

  use FountainWeb, :live_view

  require Logger

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.Conversations
  alias Fountain.Conversations.Termination
  alias Fountain.Machines.Machine

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Sandboxes")
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

  # What a stamp means, and it depends on the lease first (ADR 0058 stage 9a).
  #
  # **The lease question is asked before anything else**, because a live lease
  # means an owner is working on this machine right now whatever the stamp says
  # — the warning badge beside this note says exactly that, and a row that
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
  # finish it". `SandboxReaper.sweep_fenced_teardowns/0` finishes it.
  @doc false
  # Public so `admin_sandboxes_live_test.exs` can drive the rule directly. The
  # page-level assertion for it could only match strings over the whole
  # rendered document, which reads every other row in the table as well.
  def lease_less_note(sandbox) do
    cond do
      Machine.busy?(sandbox) -> ""
      sandbox.transition == "destroying" -> " (unfinished)"
      true -> " (abandoned)"
    end
  end

  defp assign_sandboxes(socket) do
    socket
    |> assign(:sandboxes, Conversations._unsafe_list_sandboxes_admin())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Sandboxes" current={:sandboxes}>
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
                    if(Machine.busy?(s),
                      do: warning_badge_color(),
                      else: neutral_badge_color()
                    )
                  ]}
                >
                  {s.transition}{lease_less_note(s)}
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
    </div>
    """
  end
end
