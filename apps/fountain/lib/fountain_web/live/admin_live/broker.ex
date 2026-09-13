defmodule FountainWeb.AdminLive.Broker do
  @moduledoc """
  `/admin/broker` — the egress credential broker (ADR 0019): is it up, who
  is it brokering, what did brokered sandboxes reach, and what did it refuse.

  The broker has fronted every tenant's sandbox since 2026-09-04, which made
  it the one component whose failure looks, from inside a sandbox, like the
  internet being down. Its state was on Grafana and in the per-conversation
  egress endpoint and nowhere an operator could glance at. This page is the
  glance, from `Fountain.Broker.Native.Insights`: the health tiles first,
  then the traffic over a window, then the two lists that call for action —
  what was denied and what failed — and finally the live sessions.

  Nothing here decrypts a rule, shows a credential value or names a header.
  The credential column is the *names* of the variables the proxy attached,
  which is what the audit trail records for a secret too.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.Broker.Native.Insights

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Broker")
     |> assign(:credits_enabled, Fountain.Credits.enabled?())
     |> assign(:window, 24)}
  end

  # The window lives in the URL so a refresh, a reload and a shared link all
  # keep it.
  @impl true
  def handle_params(params, _uri, socket) do
    window =
      case Integer.parse(params["window"] || "") do
        {hours, ""} -> if hours in Insights.windows(), do: hours, else: 24
        _ -> 24
      end

    {:noreply, socket |> assign(:window, window) |> assign_overview()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = refresh_overview(socket, :health)
    unless socket.redirected, do: Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_overview(socket)}
  end

  defp assign_overview(socket), do: refresh_overview(socket, :all)

  # `require_admin` runs once, at mount; a role or a session can be revoked
  # while the tab is open, so every read rechecks before it queries. The three
  # ineligible cases land where `FountainWeb.Live.Hooks` would have sent them
  # — an operator who was only demoted still holds a valid session, and a
  # login form in front of them reads as a failed login (#533).
  defp refresh_overview(socket, scope) do
    mounted = socket.assigns.current_user

    case Fountain.Accounts.get_user(mounted.id) do
      %{session_version: version} = user when version == mounted.session_version ->
        eligible(socket, user, scope)

      # No such user any more, or the session was revoked out from under it.
      _ ->
        redirect(socket, to: ~p"/auth/login")
    end
  end

  defp eligible(socket, %{email_verified_at: nil}, _scope),
    do: redirect(socket, to: ~p"/auth/verify-pending")

  defp eligible(socket, %{role: role}, _scope) when role != "admin",
    do: push_navigate(socket, to: ~p"/dashboard")

  defp eligible(socket, _user, scope) do
    overview =
      case scope do
        :all -> Insights._unsafe_overview_admin(socket.assigns.window)
        :health -> Map.merge(socket.assigns.overview, Insights._unsafe_health_admin())
      end

    assign(socket, :overview, overview)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Broker" current={:broker} credits_enabled={@credits_enabled}>
        <:subtitle>
          Health refreshes every 30s. Traffic and session details refresh on request.
        </:subtitle>
        <:actions>
          <button type="button" phx-click="refresh" class="px-2 py-1 rounded border text-xs">
            Refresh data
          </button>
          <nav class="flex items-center gap-1 text-xs" aria-label="Window">
            <.link
              :for={hours <- Insights.windows()}
              patch={~p"/admin/broker?window=#{hours}"}
              aria-current={if hours == @window, do: "page"}
              class={[
                "px-2 py-1 rounded border",
                if(hours == @window,
                  do: "bg-zinc-900 text-white border-zinc-900",
                  else: "bg-white text-zinc-600 border-zinc-300 hover:border-zinc-500"
                )
              ]}
            >
              {window_label(hours)}
            </.link>
          </nav>
        </:actions>
      </.admin_header>

      <p class="text-xs text-zinc-500">
        Counts describe recorded requests. Dropped log rows are absent; check
        <code>FountainBrokerLogDropping</code>
        in Grafana before treating counts as complete.
      </p>

      <div
        :if={!@overview.configured}
        class="bg-amber-50 border border-amber-200 rounded px-4 py-3 text-sm text-amber-900"
      >
        <span class="font-medium">This deployment does not broker.</span>
        Set <code class="font-mono text-xs">BROKER_LISTEN_PORT</code>
        and <code class="font-mono text-xs">BROKER_PROXY_URL</code>
        to run the proxy. Every tenant here is brokered once it runs.
        The figures below are whatever the log still holds.
      </div>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Health</h2>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <.tile label="Listener">
            <span class={[
              "inline-flex items-center rounded px-1.5 py-0.5 text-sm font-medium border",
              if(@overview.listener_up,
                do: "bg-green-100 text-green-800 border-green-200",
                else: "bg-red-100 text-red-700 border-red-200"
              )
            ]}>
              {if @overview.listener_up, do: "up", else: "down"}
            </span>
            <:note>on this replica</:note>
          </.tile>
          <.tile label="Live sessions">
            {@overview.sessions.live}
            <:note>
              {@overview.sessions.conversations} conversations · {@overview.sessions.expired} expired, unswept
            </:note>
          </.tile>
          <.tile label="CA expires">
            {if @overview.ca_expires_at, do: format_date(@overview.ca_expires_at), else: "—"}
            <:note>the root every sandbox trusts</:note>
          </.tile>
          <.tile label="Log retention">
            {@overview.retention_hours}h
            <:note>rows older are swept daily</:note>
          </.tile>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Traffic, last {window_label(@window)}</h2>
        <div class="grid grid-cols-2 sm:grid-cols-6 gap-3">
          <.tile label="Requests">
            {@overview.window.requests}
            <:note>
              {@overview.window.conversations} conversations · {@overview.window.tenants} tenants
            </:note>
          </.tile>
          <.tile label="Credential attached">
            {@overview.window.injected}
            <:note>{share(@overview.window.injected, @overview.window.requests)}</:note>
          </.tile>
          <.tile label="Passed through">
            {@overview.window.passthrough}
            <:note>{share(@overview.window.passthrough, @overview.window.requests)}</:note>
          </.tile>
          <.tile label="Denied" alert={@overview.window.denied > 0}>
            {@overview.window.denied}
            <:note>
              {share(@overview.window.denied, @overview.window.requests)}
              <span :if={@overview.window.no_credential > 0}>
                · {@overview.window.no_credential} for a missing credential
              </span>
            </:note>
          </.tile>
          <.tile label="Failed" alert={@overview.window.failed > 0}>
            {@overview.window.failed}
            <:note>
              {Enum.map_join(@overview.errors, " · ", &"#{&1.error} #{&1.requests}")}
            </:note>
          </.tile>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
          <div class="bg-white rounded shadow border border-zinc-200">
            <div class="px-4 py-2 text-sm font-medium border-b border-zinc-200">Hosts</div>
            <div :if={@overview.hosts == []} class="px-4 py-3 text-sm text-zinc-500">
              Nothing in this window.
            </div>
            <table :if={@overview.hosts != []} class="w-full text-sm font-mono">
              <thead class="text-left text-zinc-500 border-b border-zinc-200 text-xs">
                <tr>
                  <th class="px-4 py-2">Host</th>
                  <th class="px-4 py-2 text-right">Requests</th>
                  <th class="px-4 py-2 text-right">Credential</th>
                  <th class="px-4 py-2 text-right">Denied</th>
                  <th class="px-4 py-2 text-right">Failed</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={h <- @overview.hosts} class="border-b border-zinc-100 last:border-0">
                  <td class="px-4 py-1.5 text-xs">{h.host}</td>
                  <td class="px-4 py-1.5 text-xs text-right tabular-nums">{h.requests}</td>
                  <td class="px-4 py-1.5 text-xs text-right tabular-nums">{h.injected}</td>
                  <td class={[
                    "px-4 py-1.5 text-xs text-right tabular-nums",
                    h.denied > 0 && "text-amber-700 font-medium"
                  ]}>
                    {h.denied}
                  </td>
                  <td class={[
                    "px-4 py-1.5 text-xs text-right tabular-nums",
                    h.failed > 0 && "text-red-700 font-medium"
                  ]}>
                    {h.failed}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="bg-white rounded shadow border border-zinc-200">
            <div class="px-4 py-2 text-sm font-medium border-b border-zinc-200">
              Credentials attached, by binding
            </div>
            <div :if={@overview.services == []} class="px-4 py-3 text-sm text-zinc-500">
              No credential was attached in this window.
            </div>
            <table :if={@overview.services != []} class="w-full text-sm font-mono">
              <thead class="text-left text-zinc-500 border-b border-zinc-200 text-xs">
                <tr>
                  <th class="px-4 py-2">Binding</th>
                  <th class="px-4 py-2">Variables</th>
                  <th class="px-4 py-2 text-right">Requests</th>
                  <th class="px-4 py-2 text-right">Conversations</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={s <- @overview.services} class="border-b border-zinc-100 last:border-0">
                  <td class="px-4 py-1.5 text-xs">{s.service}</td>
                  <td class="px-4 py-1.5 text-xs text-zinc-600">
                    {Enum.join(s.credential_keys, ", ")}
                  </td>
                  <td class="px-4 py-1.5 text-xs text-right tabular-nums">{s.requests}</td>
                  <td class="px-4 py-1.5 text-xs text-right tabular-nums">{s.conversations}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Denied</h2>
        <p class="text-xs text-zinc-500">
          Every request the broker answered itself. Most are policy working: a <code>403</code>
          for a host outside a limited environment's allowed list. A
          <code>502 credential_missing</code>
          is not policy but the broker failing to hold a credential a rule names, so the request
          was refused rather than sent without one; a run of them is one tenant's secret missing,
          undecryptable or not yet granted, and this window holds
          <span class={[@overview.window.no_credential > 0 && "text-red-700 font-medium"]}>
            {@overview.window.no_credential}
          </span>
          of them. A <code>413</code>
          is a body over the size limit. The <span class="font-medium">Ended</span>
          column names which, because the binding does not reach the row: a refusal never matched
          a rule the log could record.
          Unresolved proxy tokens are refused before a request row exists and do not appear here.
          Check <code>fountain.broker.session_lookup</code>
          and the <code>FountainBrokerSessionsUnresolvable</code>
          alert for those failures.
        </p>
        <.request_table rows={@overview.denied} empty="Nothing was denied in this window." />
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Failed</h2>
        <p class="text-xs text-zinc-500">
          How forwarding ended when it did not complete. <code class="font-mono">client_closed</code>
          is the sandbox hanging up first, usually a cancelled turn;
          <code class="font-mono">upstream_*</code>
          is the origin, and a run of them on one host
          is that host having a bad time, not the broker. A refusal is not in here — it never
          forwarded, so it is counted once, under Denied.
        </p>
        <.request_table rows={@overview.failed} empty="Nothing failed in this window." />
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Live sessions</h2>
        <div :if={@overview.live_sessions == []} class="text-sm text-zinc-500">
          No sandbox holds a proxy token right now.
        </div>
        <p
          :if={@overview.live_sessions_total > length(@overview.live_sessions)}
          class="text-xs text-amber-700"
        >
          The {@overview.live_sessions_total} live sessions do not fit: these are the {length(
            @overview.live_sessions
          )} most recently minted. A conversation holds one per provision and reattach until each
          expires, so a conversation can appear more than once.
        </p>
        <table
          :if={@overview.live_sessions != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200 font-mono"
        >
          <thead class="text-left text-zinc-500 border-b border-zinc-200 text-xs">
            <tr>
              <th class="px-4 py-2">Conversation</th>
              <th class="px-4 py-2">Owner</th>
              <th class="px-4 py-2">Unmatched host</th>
              <th class="px-4 py-2">Brokered variables</th>
              <th class="px-4 py-2">Minted</th>
              <th class="px-4 py-2">Expires</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @overview.live_sessions} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-1.5 text-xs">
                <.link
                  navigate={~p"/admin/conversations/#{s.conversation_id}"}
                  class="hover:underline"
                >
                  {String.slice(s.conversation_id, 0, 8)}
                </.link>
              </td>
              <td class="px-4 py-1.5 text-xs">
                <.owner user_id={s.user_id} email={s.email} />
              </td>
              <td class="px-4 py-1.5 text-xs">{s.policy}</td>
              <td class="px-4 py-1.5 text-xs text-zinc-600">
                {if s.credential_keys == [], do: "—", else: Enum.join(s.credential_keys, ", ")}
              </td>
              <td class="px-4 py-1.5 text-xs text-zinc-500 whitespace-nowrap">
                {format_ts(s.inserted_at)}
              </td>
              <td class="px-4 py-1.5 text-xs text-zinc-500 whitespace-nowrap">
                {format_ts(s.expires_at)}
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :alert, :boolean, default: false
  slot :inner_block, required: true
  slot :note

  defp tile(assigns) do
    ~H"""
    <div class={[
      "bg-white rounded shadow border px-4 py-3",
      if(@alert, do: "border-amber-300", else: "border-zinc-200")
    ]}>
      <div class="text-xs text-zinc-500">{@label}</div>
      <div class="text-2xl font-semibold tabular-nums">{render_slot(@inner_block)}</div>
      <div :if={@note != []} class="text-xs text-zinc-500 truncate">{render_slot(@note)}</div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :empty, :string, required: true

  defp request_table(assigns) do
    ~H"""
    <div :if={@rows == []} class="text-sm text-zinc-500">{@empty}</div>
    <table
      :if={@rows != []}
      class="w-full text-sm bg-white rounded shadow border border-zinc-200 font-mono"
    >
      <thead class="text-left text-zinc-500 border-b border-zinc-200 text-xs">
        <tr>
          <th class="px-4 py-2">When</th>
          <th class="px-4 py-2">Request</th>
          <th class="px-4 py-2">Ended</th>
          <th class="px-4 py-2">Conversation</th>
          <th class="px-4 py-2">Owner</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={r <- @rows} class="border-b border-zinc-100 last:border-0">
          <td class="px-4 py-1.5 text-xs text-zinc-500 whitespace-nowrap">
            {format_ts(r.inserted_at)}
          </td>
          <td class="px-4 py-1.5 text-xs">
            {r.method} {r.host}<span class="text-zinc-500">{String.slice(r.path, 0, 60)}</span>
          </td>
          <td class="px-4 py-1.5 text-xs text-zinc-600">
            {[r.status, r.error] |> Enum.reject(&is_nil/1) |> Enum.join(" ")}
          </td>
          <td class="px-4 py-1.5 text-xs">
            <.link navigate={~p"/admin/conversations/#{r.conversation_id}"} class="hover:underline">
              {String.slice(r.conversation_id, 0, 8)}
            </.link>
          </td>
          <td class="px-4 py-1.5 text-xs">
            <.owner user_id={r.user_id} email={r.email} />
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :user_id, :string, default: nil
  attr :email, :string, default: nil

  defp owner(assigns) do
    ~H"""
    <.link :if={@email} navigate={~p"/admin/users/#{@user_id}"} class="hover:underline">
      {@email}
    </.link>
    <span :if={is_nil(@email)} class="text-zinc-400">deleted</span>
    """
  end

  defp window_label(1), do: "1h"
  defp window_label(24), do: "24h"
  defp window_label(168), do: "7d"
  defp window_label(hours), do: "#{hours}h"

  defp share(_part, 0), do: "—"
  defp share(part, whole), do: "#{round(part / whole * 100)}% of requests"
end
