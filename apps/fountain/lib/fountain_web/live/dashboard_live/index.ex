defmodule FountainWeb.DashboardLive.Index do
  @moduledoc """
  The console's home: the account's own numbers, and the way in to its
  primitives.

  It is also where a newly verified or signed-in account lands: `/` and the
  verification link both send people here. Getting started is the manual's
  quickstart (`/docs/quickstart`), not a page of its own.
  """
  use FountainWeb, :live_view

  alias Fountain.{
    Agents,
    Apps,
    Conversations,
    Environments,
    Vaults
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    agents = Agents.list_agents(user.id, [])
    counts = Conversations.conversation_counts(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:agent_count, length(agents))
     |> assign(:environment_count, length(Environments.list_environments(user.id)))
     |> assign(:vault_count, length(Vaults.list_vaults(user.id)))
     |> assign(:active_count, counts.active)
     |> assign(:conversation_count, counts.total)
     |> assign(:conversations_app, Apps.conversations())
     |> assign(:team_app, Apps.team())
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

  # The calendar month, from usage events, so the console sees what the
  # account's agents have been doing.
  defp assign_usage(socket, user) do
    period = Fountain.Usage.month_range()

    socket
    |> assign(:usage, Fountain.Usage.usage_summary(user.id, period.start, period.end))
    |> assign(:tokens, Conversations.token_usage(user.id, period.start, period.end))
    |> assign(:period, period)
    |> assign(:period_start, period.start)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Dashboard</h1>
        <a :if={@conversations_app} href={@conversations_app <> "#/new"}>
          <.button>Start a conversation ↗</.button>
        </a>
      </div>

      <%!-- The apps. External on purpose: their own origins, their own
            tokens, and a deployment may have neither. --%>
      <section :if={@conversations_app || @team_app}>
        <h2 class="text-lg font-medium mb-3">Apps</h2>
        <div class="grid gap-4 sm:grid-cols-2">
          <.app_card
            :if={@conversations_app}
            href={@conversations_app}
            title="Conversations"
            body="Start a run, watch it turn by turn, steer it, read the raw log."
          />
          <.app_card
            :if={@team_app}
            href={@team_app}
            title="Team"
            body="Your agents as teammates — one thread each, schedules, and their activity."
          />
        </div>
      </section>

      <section>
        <div class="flex items-baseline justify-between mb-3">
          <h2 class="text-lg font-medium">
            This month
          </h2>
          <span class="text-xs text-[var(--color-text-muted)]">
            since {Calendar.strftime(@period_start, "%-d %B")}
          </span>
        </div>
        <div class="grid gap-4 grid-cols-2 lg:grid-cols-4">
          <.metric label="Conversations" value={format_count(@usage.conversations)} />
          <.metric label="Turns" value={format_count(@usage.turns)} />
          <%!-- Turn hours, not sandbox time: sandbox wall-clock went up while
                nobody was talking to the agent. The sandbox figure stays in
                the hint, where it explains itself. --%>
          <.metric
            label="Turn hours"
            value={turn_hours_value(assigns)}
            sub={turn_hours_sub(assigns)}
            hint={turn_hours_hint(assigns)}
          />
          <.metric
            label="Tokens"
            value={format_tokens(@tokens)}
            sub={token_sub(@tokens)}
            hint={token_hint(@tokens)}
          />
        </div>
        <%!-- Only when every tile is empty. Usage events are best-effort
              (`Fountain.Usage.record_usage/5` swallows its failures), so an instance
              can have turns and tokens with no events behind them — and
              "nothing yet" above four populated tiles reads as a bug. --%>
        <p :if={nothing_this_month?(assigns)} class="mt-2 text-xs text-[var(--color-text-muted)]">
          Nothing yet this month.
        </p>
      </section>

      <section>
        <h2 class="text-lg font-medium mb-3">What you have</h2>
        <div class="grid gap-4 grid-cols-2 lg:grid-cols-4">
          <.stat_card label="Agents" value={@agent_count} href={~p"/agents"} />
          <.stat_card label="Environments" value={@environment_count} href={~p"/environments"} />
          <.stat_card label="Vaults" value={@vault_count} href={~p"/vaults"} />
          <.stat_card label="Running now" value={@active_count} href={@conversations_app} external />
        </div>
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
          Transcripts live in the conversations app; this console keeps the account and the
          primitives a conversation runs on.
        </p>
      </section>
    </div>
    """
  end

  defp nothing_this_month?(assigns) do
    assigns.usage.conversations == 0 and assigns.usage.turns == 0 and
      assigns.usage.sandbox_minutes == 0 and Conversations.total_input(assigns.tokens) == 0 and
      assigns.tokens.output == 0
  end

  # Turn hours used, rounded to one place, which is the resolution a person
  # can act on.
  defp turn_hours_value(%{usage: usage}), do: format_hours(billable_turn_hours(usage))

  defp turn_hours_sub(_assigns), do: nil

  defp turn_hours_hint(assigns) do
    base =
      "Time with a prompt in flight. An agent left running with nobody talking to it " <>
        "spends none of this."

    case assigns.usage.sandbox_minutes do
      minutes when minutes > 0 ->
        base <> " Your sandboxes were awake for #{format_minutes(minutes)}."

      _ ->
        base
    end
  end

  # Turn time on the providers the platform pays for, which excludes a
  # tenant's own runner (ADR 0022); `Fountain.Usage.usage_summary/3` does the sum.
  defp billable_turn_hours(usage) do
    Map.get(usage, :turn_hours, 0.0)
  end

  defp format_hours(hours) when is_number(hours) do
    cond do
      hours == 0 -> "0"
      hours < 0.1 -> "<0.1"
      true -> "#{Float.round(hours * 1.0, 1)}"
    end
  end

  defp format_hours(_), do: "—"

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

  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  defp app_card(assigns) do
    ~H"""
    <a
      href={@href}
      class="block rounded-lg border border-[var(--color-border)] p-4 hover:bg-[var(--color-bg-2)] transition-colors"
    >
      <p class="font-medium">{@title} ↗</p>
      <p class="mt-1 text-sm text-[var(--color-text-secondary)]">{@body}</p>
    </a>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :href, :string, default: nil
  attr :external, :boolean, default: false

  defp stat_card(assigns) do
    ~H"""
    <div :if={is_nil(@href)} class="rounded-lg border border-[var(--color-border)] p-4">
      <p class="text-xs uppercase tracking-wide text-[var(--color-text-muted)]">{@label}</p>
      <p class="mt-1 text-2xl font-semibold">{@value}</p>
    </div>
    <a
      :if={@href && @external}
      href={@href}
      class="block rounded-lg border border-[var(--color-border)] p-4 hover:bg-[var(--color-bg-2)] transition-colors"
    >
      <p class="text-xs uppercase tracking-wide text-[var(--color-text-muted)]">{@label} ↗</p>
      <p class="mt-1 text-2xl font-semibold">{@value}</p>
    </a>
    <.link
      :if={@href && not @external}
      navigate={@href}
      class="block rounded-lg border border-[var(--color-border)] p-4 hover:bg-[var(--color-bg-2)] transition-colors"
    >
      <p class="text-xs uppercase tracking-wide text-[var(--color-text-muted)]">{@label}</p>
      <p class="mt-1 text-2xl font-semibold">{@value}</p>
    </.link>
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

  # Minutes until they stop being readable as minutes.
  defp format_minutes(minutes) when is_number(minutes) do
    cond do
      minutes < 1 -> "<1m"
      minutes < 60 -> "#{round(minutes)}m"
      minutes < 60 * 24 -> "#{Float.round(minutes / 60, 1)}h"
      true -> "#{Float.round(minutes / 60 / 24, 1)}d"
    end
  end

  defp format_minutes(_), do: "—"

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
      "On your own inference key — Fountain never bills for these."

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
