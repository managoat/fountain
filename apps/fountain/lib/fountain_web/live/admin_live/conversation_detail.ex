defmodule FountainWeb.AdminLive.ConversationDetail do
  @moduledoc """
  Admin support view of any tenant's conversation (#446). This is the page the
  admin sandbox table links to — until it existed, those links resolved
  through the tenant-scoped conversation page and 404ed for every conversation
  the admin didn't own. That page is the standalone app's now (#867); this one
  stays, because an operator has to be able to look at a conversation they do
  not own.

  **Metadata only, by design.** Status, timing, turn numbers, exit codes and
  counts are visible; prompts, outputs and log content are not — support can
  see *that* turn 7 failed with exit 137 without reading what the user typed.
  Titles are shown (they're how a user refers to their conversation in a
  support thread) and are the only content-derived field on the page. Each
  visit records an `admin.conversation.viewed` admin audit event.
  """
  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.{Audit, Conversations}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Ownership context for the _unsafe_ calls: admin surface behind
    # require_admin (router :admin live_session).
    case Conversations._unsafe_get_conversation_admin(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Conversation not found")
         |> push_navigate(to: ~p"/admin/sandboxes")}

      %{conversation: conv, turn_count: turn_count, log_event_count: log_event_count} ->
        # connected?-guard: mount runs for both the static render and the
        # socket; one visit must be one audit row.
        if connected?(socket) do
          Audit.record_admin(%{
            actor_user_id: socket.assigns.current_user.id,
            target_user_id: conv.user_id,
            event_type: "admin.conversation.viewed",
            metadata: %{
              "email" => conv.user && conv.user.email,
              "conversation_id" => conv.id
            }
          })
        end

        {:ok,
         socket
         |> assign(:page_title, "Admin · conversation #{String.slice(conv.id, 0, 8)}")
         |> assign(:conv, conv)
         |> assign(:turn_count, turn_count)
         |> assign(:log_event_count, log_event_count)
         |> assign(:turns, Conversations._unsafe_list_turn_summaries_admin(conv.id))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.admin_tabs current={:sandboxes} />
        <h1 class="text-2xl font-semibold mt-4">
          <span class="font-mono">{String.slice(@conv.id, 0, 8)}</span>
          <span :if={@conv.title} class="text-[var(--color-text-secondary)] text-lg ml-2">{@conv.title}</span>
        </h1>
        <div class="flex flex-wrap items-center gap-2 mt-2 text-xs">
          <span class={[
            "inline-flex items-center rounded px-1.5 py-0.5 font-medium border",
            conversation_status_color(@conv.status)
          ]}>
            {@conv.status}
          </span>
          <span class="text-[var(--color-text-secondary)]">runtime {@conv.runtime}</span>
          <span :if={@conv.source} class="text-[var(--color-text-secondary)]">via {@conv.source}</span>
        </div>
        <p class="text-xs text-[var(--color-text-muted)] mt-2 font-mono">{@conv.id}</p>
      </div>

      <section class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <div class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3">
          <div class="text-xs text-[var(--color-text-secondary)]">Owner</div>
          <div class="text-sm font-medium font-mono truncate">
            <.link
              :if={@conv.user}
              navigate={~p"/admin/users/#{@conv.user.id}"}
              class="hover:underline"
            >
              {@conv.user.email}
            </.link>
            <span :if={is_nil(@conv.user)}>—</span>
          </div>
        </div>
        <div class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3">
          <div class="text-xs text-[var(--color-text-secondary)]">Agent</div>
          <div class="text-sm font-medium truncate">
            {if @conv.agent, do: @conv.agent.name, else: "—"}
          </div>
        </div>
        <div class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3">
          <div class="text-xs text-[var(--color-text-secondary)]">Sandbox</div>
          <div class="text-sm font-medium font-mono">
            {if @conv.sandbox, do: String.slice(@conv.sandbox.id, 0, 8), else: "—"}
          </div>
          <div :if={@conv.sandbox} class="text-xs text-[var(--color-text-secondary)]">
            {@conv.sandbox.status}
          </div>
        </div>
        <div class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3">
          <div class="text-xs text-[var(--color-text-secondary)]">Volume</div>
          <div class="text-sm font-medium tabular-nums">
            {@turn_count} turns · {@log_event_count} log events
          </div>
          <div class="text-xs text-[var(--color-text-secondary)]">
            started {format_ts(@conv.inserted_at)}
          </div>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Turns (latest {length(@turns)})</h2>
        <p class="text-sm text-[var(--color-text-secondary)]">
          Metadata only — prompt and output content are not shown to admins.
        </p>
        <div :if={@turns == []} class="text-sm text-[var(--color-text-secondary)]">None.</div>
        <table
          :if={@turns != []}
          class="w-full text-sm bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)]"
        >
          <thead class="text-left text-[var(--color-text-secondary)] border-b border-[var(--color-border)]">
            <tr>
              <th class="px-4 py-2">#</th>
              <th class="px-4 py-2">Status</th>
              <th class="px-4 py-2">Exit</th>
              <th class="px-4 py-2">Started</th>
              <th class="px-4 py-2">Ended</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={t <- @turns} class="border-b border-[var(--color-border)] last:border-0">
              <td class="px-4 py-2 text-xs tabular-nums">{t.turn_number}</td>
              <td class="px-4 py-2">
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                  conversation_status_color(t.status)
                ]}>
                  {t.status}
                </span>
              </td>
              <td class="px-4 py-2 text-xs tabular-nums">
                {if is_nil(t.exit_code), do: "—", else: t.exit_code}
              </td>
              <td class="px-4 py-2 text-xs text-[var(--color-text-secondary)]">
                {format_ts(t.started_at || t.inserted_at)}
              </td>
              <td class="px-4 py-2 text-xs text-[var(--color-text-secondary)]">
                {format_ts(t.ended_at)}
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end
end
