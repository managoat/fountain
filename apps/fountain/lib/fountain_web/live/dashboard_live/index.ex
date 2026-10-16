defmodule FountainWeb.DashboardLive.Index do
  @moduledoc """
  The API starting point: a first request, docs and account links, followed
  by the signed-in user's usage, recent audit events and conversations.
  """
  use FountainWeb, :live_view

  alias Fountain.{Apps, Audit, Conversations}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    counts = Conversations.conversation_counts(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:server_url, FountainWeb.Endpoint.url())
     |> assign(:api_example, api_example())
     |> assign(:recent_events, Audit.list_for_user(user.id, limit: 3))
     |> assign(:active_count, counts.active)
     |> assign(:conversations_app, Apps.conversations())
     |> assign_usage(user)}
  end

  # The recent-conversations list takes a `label` filter from the URL, the way
  # /audit takes its filters (#1637): repeatable, AND-combined, and a link you
  # can send someone. `uri` rather than `params` because Plug collapses a
  # repeated query key to its last value and this filter is repeatable.
  #
  # A filter value the vocabulary does not recognise filters nothing and
  # leaves the chips showing what was asked for, the same way the audit page
  # treats a half-typed date.
  @impl true
  def handle_params(_params, uri, socket) do
    user = socket.assigns.current_user

    labels =
      case FountainWeb.LabelFilter.from_uri(uri) do
        {:ok, labels} -> labels
        {:error, _invalid} -> %{}
      end

    {:noreply,
     socket
     |> assign(:label_filter, labels)
     |> assign(
       :recent_conversations,
       Conversations.list_conversations(user.id, limit: 5, labels: labels)
     )}
  end

  # The path a chip links to: this label added to whatever is already
  # filtered, so two clicks narrow rather than replace.
  #
  # Built by hand rather than through `~p`'s query encoding, because the
  # filter is a *repeated* `label=` key and the sigil builds a map.
  defp dashboard_path(filter) do
    case Enum.map_join(Enum.sort(filter), "&", &label_param/1) do
      "" -> ~p"/dashboard"
      query -> ~p"/dashboard" <> "?" <> query
    end
  end

  defp label_param({key, value}),
    do: "label=" <> URI.encode_www_form("#{key}:#{value}")

  # The running UTC calendar month, counted from the conversations and turns
  # tables (ADR 0079), so the console sees what the account's agents have been
  # doing.
  defp assign_usage(socket, user) do
    today = Date.utc_today()
    period_start = DateTime.new!(Date.beginning_of_month(today), ~T[00:00:00])
    period_end = DateTime.new!(Date.add(Date.end_of_month(today), 1), ~T[00:00:00])

    socket
    |> assign(:activity, Conversations.activity_counts(user.id, period_start, period_end))
    |> assign(:tokens, Conversations.token_usage(user.id, period_start, period_end))
    |> assign(:period_start, period_start)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex flex-wrap justify-between items-start gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Dashboard</h1>
          <p class="mt-2 text-[var(--color-text-secondary)]">
            Start with the API. Keep track of what your agents are doing.
          </p>
        </div>
        <p class="text-sm text-[var(--color-text-secondary)]">
          Running now:
          <span class="font-semibold text-[var(--color-text-primary)]">{@active_count}</span>
        </p>
      </div>

      <section id="api-introduction" aria-labelledby="api-heading" class="space-y-5">
        <div class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 id="api-heading" class="text-lg font-semibold">Make your first API request</h2>
          <a href={~p"/docs/quickstart"} class="text-sm text-[var(--color-brand)] hover:underline">Read the quickstart →</a>
        </div>
        <p class="text-sm text-[var(--color-text-secondary)]">
          <a href={Apps.account_url("api-keys")} class="text-[var(--color-brand)] underline">Create an API key</a>,
          replace the placeholder below, and run this in your terminal to fetch your account.
        </p>
        <div class="rounded-lg border border-[var(--color-border)] overflow-hidden">
          <div class="flex flex-wrap items-center justify-between gap-3 px-4 py-3 bg-[var(--color-bg-1)] border-b border-[var(--color-border)]">
            <p class="text-xs text-[var(--color-text-secondary)]">
              Your server: <code class="break-all">{@server_url}</code>
            </p>
            <button
              id="copy-api-example"
              type="button"
              phx-hook="CopyToClipboard"
              data-target="api-example"
              class="text-sm font-medium text-[var(--color-brand)] hover:underline"
            >Copy request</button>
          </div>
          <pre class="p-4 text-xs sm:text-sm overflow-x-auto bg-[var(--color-code-bg)] text-[var(--color-code-text)]"><code id="api-example">{@api_example}</code></pre>
        </div>
        <p class="text-sm text-[var(--color-text-secondary)]">
          Next: create an agent and start a conversation.
          <a href={~p"/docs/api"} class="text-[var(--color-brand)] underline">API reference</a>
          · <a href={~p"/docs/cli"} class="text-[var(--color-brand)] underline">CLI guide</a>
        </p>
      </section>

      <nav
        aria-label="Your workspace"
        class="flex flex-wrap gap-x-6 gap-y-3 border-y border-[var(--color-border)] py-4 text-sm font-medium text-[var(--color-brand)]"
      >
        <a href={~p"/audit"} class="hover:underline">View audit log →</a>
        <a :if={@conversations_app} href={@conversations_app} class="hover:underline">Open conversations ↗</a>
        <a href={Apps.account_url()} class="hover:underline">Settings</a>
      </nav>

      <section>
        <div class="flex items-baseline justify-between mb-3">
          <h2 class="text-lg font-medium">
            This month
          </h2>
          <span class="text-xs text-[var(--color-text-muted)]">
            since {Calendar.strftime(@period_start, "%-d %B")}
          </span>
        </div>
        <div class="grid gap-4 grid-cols-2 lg:grid-cols-3">
          <.metric label="Conversations" value={format_count(@activity.conversations)} />
          <.metric label="Turns" value={format_count(@activity.turns)} />
          <.metric
            label="Tokens"
            value={format_tokens(@tokens)}
            sub={token_sub(@tokens)}
            hint={token_hint(@tokens)}
          />
        </div>
        <%!-- Only when every tile is empty. --%>
        <p :if={nothing_this_month?(assigns)} class="mt-2 text-xs text-[var(--color-text-muted)]">
          Nothing yet this month.
        </p>
      </section>

      <section aria-labelledby="recent-activity-heading">
        <div class="flex items-baseline justify-between gap-3 mb-3">
          <h2 id="recent-activity-heading" class="text-lg font-medium">Recent activity</h2>
          <a href={~p"/audit"} class="text-sm text-[var(--color-brand)] hover:underline">View audit log →</a>
        </div>
        <p :if={@recent_events == []} class="text-sm text-[var(--color-text-secondary)]">
          No activity yet. Your account’s changes will appear here.
        </p>
        <ul id="recent-activity" class="divide-y divide-[var(--color-border)]">
          <li
            :for={event <- @recent_events}
            class="py-3 flex flex-wrap items-center justify-between gap-2 text-sm"
          >
            <div>
              <span class="font-medium">{event.action}</span><span class="ml-2 text-[var(--color-text-secondary)]">{event.resource_type}</span>
            </div>
            <time
              datetime={DateTime.to_iso8601(event.inserted_at)}
              class="text-xs text-[var(--color-text-muted)]"
            >{relative_time(event.inserted_at)}</time>
          </li>
        </ul>
      </section>

      <section :if={@recent_conversations != [] or @label_filter != %{}}>
        <div class="flex items-baseline justify-between mb-3">
          <h2 class="text-lg font-medium">Recent conversations</h2>
          <span :if={@label_filter != %{}} class="text-xs">
            <.label_chips labels={@label_filter} />
            <.link patch={~p"/dashboard"} class="ml-2 text-[var(--color-text-muted)] hover:underline">
              clear
            </.link>
          </span>
        </div>
        <p
          :if={@recent_conversations == []}
          class="rounded-lg border border-[var(--color-border)] px-4 py-3 text-sm text-[var(--color-text-muted)]"
        >
          No conversation carries every one of those labels.
        </p>
        <div
          :if={@recent_conversations != []}
          class="overflow-hidden rounded-lg border border-[var(--color-border)]"
        >
          <table class="w-full text-sm">
            <tbody>
              <tr
                :for={c <- @recent_conversations}
                class="border-b border-[var(--color-border)] last:border-0"
              >
                <td class="px-4 py-2">
                  <.conv_link conversation={c} app={@conversations_app} />
                  <.label_chips
                    labels={c.labels}
                    href={fn {key, value} -> dashboard_path(Map.put(@label_filter, key, value)) end}
                  />
                </td>
                <td class="px-4 py-2"><.badge status={c.status} /></td>
                <td class="px-4 py-2 text-[var(--color-text-muted)] text-xs">
                  {relative_time(c.updated_at)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="mt-2 text-xs text-[var(--color-text-muted)]">
          Open a conversation to read its transcript and continue the work.
        </p>
      </section>
    </div>
    """
  end

  defp api_example do
    url = String.replace(FountainWeb.Endpoint.url(), "'", "'\\''")

    "export MANAGOAT_API_KEY='paste-your-key-here'\n" <>
      "curl --fail-with-body '#{url}/api/auth/me' \\\n  -H \"Authorization: Bearer $MANAGOAT_API_KEY\""
  end

  defp nothing_this_month?(assigns) do
    assigns.activity.turns == 0 and Conversations.total_input(assigns.tokens) == 0 and
      assigns.tokens.output == 0
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :hint, :string, default: nil

  defp metric(assigns) do
    ~H"""
    <div class="rounded-lg border border-[var(--color-border)] p-4" title={@hint}>
      <p class="text-xs uppercase tracking-wide text-[var(--color-text-muted)]">{@label}</p>
      <p class="mt-1 text-2xl font-semibold tabular-nums">{@value}</p>
      <p :if={@sub} class="text-[11px] text-[var(--color-text-muted)]">{@sub}</p>
    </div>
    """
  end

  attr :conversation, :map, required: true
  attr :app, :string, default: nil

  defp conv_link(assigns) do
    assigns = assign(assigns, :name, agent_name(assigns.conversation))

    ~H"""
    <a
      :if={@app}
      href={Fountain.Apps.conversation_url(@conversation.id)}
      class="font-medium hover:underline"
    >
      {@name} ↗
    </a>
    <span :if={is_nil(@app)} class="font-medium">{@name}</span>
    """
  end

  # Thousands separators, because six figures of tokens is unreadable without.
  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_count(n), do: to_string(n)

  # Two numbers in one tile: what went in, what came back. "In" is every
  # token the model read — a coding agent re-reads its context every turn, so
  # nearly all of it arrives as cached reads, and `input` alone reads as
  # nothing at all.
  defp format_tokens(tokens) do
    case {Conversations.total_input(tokens), tokens.output} do
      {0, 0} -> "—"
      {input, output} -> "#{compact(input)} / #{compact(output)}"
    end
  end

  defp token_sub(tokens) do
    if Conversations.total_input(tokens) > 0 or tokens.output > 0, do: "in / out"
  end

  # The breakdown belongs somewhere, and a tile is not it — but a reader who
  # wonders why "in" is so large deserves the answer on hover.
  defp token_hint(tokens) do
    cached = tokens.cache_read + tokens.cache_write

    base =
      "On your own inference key — Managoat never bills for these."

    if cached > 0 do
      base <>
        " In includes #{format_count(cached)} read from or written to the prompt cache," <>
        " and #{format_count(tokens.input)} fresh."
    else
      base
    end
  end

  defp compact(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp compact(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp compact(n), do: Integer.to_string(n)

  defp agent_name(%{agent: %{name: name}}), do: name
  defp agent_name(_), do: "(no agent)"

  defp relative_time(nil), do: ""

  defp relative_time(dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt))

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
