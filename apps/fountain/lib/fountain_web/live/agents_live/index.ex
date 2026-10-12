defmodule FountainWeb.AgentsLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Agents
  alias Fountain.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id
    all_agents = Agents.list_agents_with_counts(user_id, [])

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:user_id, user_id)
     |> assign(:agents, all_agents)
     |> assign(:facet_counts, compute_facets(all_agents))
     |> assign(:all_environments, extract_environments(all_agents))
     |> assign(:filter_search, "")
     |> assign(:filter_runtimes, [])
     |> assign(:filter_env_ids, [])
     |> assign(:filter_has_skills, false)
     |> assign(:filter_has_mcp, false)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    search = params |> Map.get("search", "") |> String.trim()
    runtimes = Map.get(params, "runtimes", [])
    env_ids = Map.get(params, "env_ids", [])
    has_skills = Map.has_key?(params, "has_skills")
    has_mcp = Map.has_key?(params, "has_mcp")

    filters = [
      search: search,
      runtimes: runtimes,
      env_ids: env_ids,
      has_skills: has_skills,
      has_mcp: has_mcp
    ]

    {:noreply,
     socket
     |> assign(:filter_search, search)
     |> assign(:filter_runtimes, runtimes)
     |> assign(:filter_env_ids, env_ids)
     |> assign(:filter_has_skills, has_skills)
     |> assign(:filter_has_mcp, has_mcp)
     |> assign(:agents, Agents.list_agents_with_counts(socket.assigns.user_id, filters))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filter_search, "")
     |> assign(:filter_runtimes, [])
     |> assign(:filter_env_ids, [])
     |> assign(:filter_has_skills, false)
     |> assign(:filter_has_mcp, false)
     |> assign(:agents, Agents.list_agents_with_counts(socket.assigns.user_id, []))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id

    # Non-bang + nil branch (#401): the list is loaded at mount, so a row
    # deleted from another tab or the API made get_agent! raise and kill
    # the LiveView on the second click.
    case Agents.get_agent(id, user_id) do
      nil ->
        {:noreply,
         socket
         |> assign(
           :agents,
           Agents.list_agents_with_counts(user_id, current_filters(socket.assigns))
         )
         |> put_flash(:error, "Agent not found — it may already be deleted")}

      agent ->
        {:ok, _} = Agents.delete_agent(agent, FountainWeb.Audited.attribution(socket))
        delete_refresh(socket, user_id, agent)
    end
  end

  defp delete_refresh(socket, user_id, agent) do
    all_agents = Agents.list_agents_with_counts(user_id, [])
    filters = current_filters(socket.assigns)

    {:noreply,
     socket
     |> assign(:agents, Agents.list_agents_with_counts(user_id, filters))
     |> assign(:facet_counts, compute_facets(all_agents))
     |> assign(:all_environments, extract_environments(all_agents))
     |> put_flash(:info, "Deleted #{agent.name}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex gap-6 items-start">
      <%!-- Filter sidebar --%>
      <aside class="w-52 shrink-0 space-y-5">
        <form phx-change="filter" phx-submit="filter" class="space-y-5">
          <%!-- Search --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Search</p>
            <input
              type="text"
              name="search"
              value={@filter_search}
              phx-debounce="200"
              placeholder="Agent name…"
              class="w-full rounded border border-zinc-300 px-2 py-1 text-sm focus:outline-none focus:border-zinc-500 bg-white"
            />
          </div>

          <%!-- Runtime facet --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Runtime</p>
            <div class="space-y-1.5">
              <label
                :for={rt <- Agent.runtimes()}
                class="flex items-center justify-between gap-2 text-sm cursor-pointer"
              >
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="runtimes[]"
                    value={rt}
                    checked={rt in @filter_runtimes}
                    class="rounded border-zinc-300"
                  />
                  {rt}
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.runtimes, rt, 0)}</span>
              </label>
            </div>
          </div>

          <%!-- Environment facet --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">
              Environment
            </p>
            <div class="space-y-1.5">
              <label class="flex items-center justify-between gap-2 text-sm cursor-pointer">
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="env_ids[]"
                    value="none"
                    checked={"none" in @filter_env_ids}
                    class="rounded border-zinc-300"
                  />
                  <span class="italic text-zinc-400">None</span>
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.env_ids, "none", 0)}</span>
              </label>
              <label
                :for={env <- @all_environments}
                class="flex items-center justify-between gap-2 text-sm cursor-pointer"
              >
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="env_ids[]"
                    value={env.id}
                    checked={env.id in @filter_env_ids}
                    class="rounded border-zinc-300"
                  />
                  {env.name}
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.env_ids, env.id, 0)}</span>
              </label>
            </div>
          </div>

          <%!-- Capability facets --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">
              Capabilities
            </p>
            <div class="space-y-1.5">
              <label class="flex items-center gap-1.5 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  name="has_skills"
                  value="true"
                  checked={@filter_has_skills}
                  class="rounded border-zinc-300"
                /> Has skills
              </label>
              <label class="flex items-center gap-1.5 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  name="has_mcp"
                  value="true"
                  checked={@filter_has_mcp}
                  class="rounded border-zinc-300"
                /> Has MCP servers
              </label>
            </div>
          </div>
        </form>

        <button
          :if={filters_active?(assigns)}
          phx-click="clear_filters"
          class="text-xs text-zinc-400 hover:text-zinc-700 underline underline-offset-2"
        >
          Clear all filters
        </button>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 min-w-0 space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-semibold">Agents</h1>
          <.link href={~p"/agents/new"}>
            <.button>+ New agent</.button>
          </.link>
        </div>

        <div
          :if={@agents == [] and not filters_active?(assigns)}
          class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500"
        >
          No agents yet.
        </div>

        <div
          :if={@agents == [] and filters_active?(assigns)}
          class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500"
        >
          No agents match the current filters.
        </div>

        <table
          :if={@agents != []}
          class="w-full text-sm rounded-lg overflow-hidden bg-[var(--color-bg-1)] border border-[var(--color-border)]"
        >
          <thead class="border-b border-[var(--color-border)]">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
                Name
              </th>
              <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
                Runtime
              </th>
              <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
                Model
              </th>
              <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
                Stats
              </th>
              <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
                Env
              </th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={a <- @agents}
              class="border-b border-[var(--color-border)] last:border-0 hover:bg-[var(--color-bg-2)] transition-colors duration-150"
            >
              <td class="px-4 py-3">
                <div class="flex items-center gap-2.5">
                  <img
                    :if={a.avatar_media_type}
                    src={~p"/agents/#{a.id}/avatar"}
                    class="w-7 h-7 rounded-md object-cover shrink-0"
                    alt=""
                  />
                  <span class="font-medium text-[var(--color-text-primary)]">{a.name}</span>
                </div>
              </td>
              <td class="px-4 py-3">
                <span class={[
                  "inline-flex items-center gap-1 px-2 py-1 rounded text-xs font-semibold",
                  runtime_badge_class(a.runtime)
                ]}>
                  <span class="w-1.5 h-1.5 rounded-full" style="background:currentColor;"></span>
                  {a.runtime}
                </span>
              </td>
              <td class="px-4 py-3 font-mono text-xs text-[var(--color-text-muted)]">{a.model}</td>
              <td class="px-4 py-3">
                <div class="flex items-center gap-1.5 flex-wrap">
                  <span
                    class={[
                      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
                      stat_badge_class(:skills, length(a.skills))
                    ]}
                    title={"#{length(a.skills)} skills"}
                  >
                    ⚡ {length(a.skills)}
                  </span>
                  <span
                    class={[
                      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
                      stat_badge_class(:mcp, map_size(a.mcp_servers))
                    ]}
                    title={"#{map_size(a.mcp_servers)} MCP servers"}
                  >
                    🔌 {map_size(a.mcp_servers)}
                  </span>
                  <span
                    class={[
                      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
                      stat_badge_class(:conversations, a.conversation_count)
                    ]}
                    title={"#{a.conversation_count} total conversations"}
                  >
                    💬 {a.conversation_count}
                  </span>
                </div>
              </td>
              <td class="px-4 py-3">
                <span
                  :if={a.environment}
                  class={[
                    "inline-flex items-center px-2 py-1 rounded text-xs font-medium",
                    env_badge_class(a.environment.name)
                  ]}
                >
                  {a.environment.name}
                </span>
                <span :if={!a.environment} class="text-[var(--color-text-muted)]">—</span>
              </td>
              <td class="px-4 py-3 text-right">
                <div class="inline-flex gap-1">
                  <.link href={~p"/agents/#{a.id}/edit"}>
                    <.button variant="secondary">Edit</.button>
                  </.link>
                  <button
                    class="px-2 py-1 rounded text-xs cursor-pointer bg-[var(--color-error-bg)] border border-[var(--color-error)] text-[var(--color-error-text)] hover:bg-[var(--color-error)] hover:text-white transition-colors"
                    phx-click="delete"
                    phx-value-id={a.id}
                    data-confirm="Delete agent?"
                  >
                    Delete
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp compute_facets(agents) do
    runtimes = Enum.frequencies_by(agents, & &1.runtime)

    env_ids =
      Enum.frequencies_by(agents, fn a ->
        if a.environment_id, do: a.environment_id, else: "none"
      end)

    %{runtimes: runtimes, env_ids: env_ids}
  end

  defp extract_environments(agents) do
    agents
    |> Enum.map(& &1.environment)
    |> Enum.filter(& &1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.name)
  end

  defp current_filters(assigns) do
    [
      search: assigns.filter_search,
      runtimes: assigns.filter_runtimes,
      env_ids: assigns.filter_env_ids,
      has_skills: assigns.filter_has_skills,
      has_mcp: assigns.filter_has_mcp
    ]
  end

  defp filters_active?(assigns) do
    assigns.filter_search != "" or
      assigns.filter_runtimes != [] or
      assigns.filter_env_ids != [] or
      assigns.filter_has_skills or
      assigns.filter_has_mcp
  end

  defp runtime_badge_class("claude"),
    do:
      "bg-[var(--color-success-bg)] text-[var(--color-success-text)] border border-[var(--color-success)]"

  defp runtime_badge_class("gemini"),
    do:
      "bg-[var(--color-info-bg)] text-[var(--color-info-text)] border border-[var(--color-info)]"

  defp runtime_badge_class("codex"),
    do:
      "bg-[var(--color-warning-bg)] text-[var(--color-warning-text)] border border-[var(--color-warning)]"

  defp runtime_badge_class(_),
    do:
      "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)] border border-[var(--color-border)]"

  defp stat_badge_class(_type, 0),
    do:
      "bg-[var(--color-bg-2)] text-[var(--color-text-muted)] border border-[var(--color-border)]"

  defp stat_badge_class(:skills, _),
    do:
      "bg-[var(--color-success-bg)] text-[var(--color-success-text)] border border-[var(--color-success)]"

  defp stat_badge_class(:mcp, _),
    do:
      "bg-[var(--color-info-bg)] text-[var(--color-info-text)] border border-[var(--color-info)]"

  defp stat_badge_class(:conversations, _),
    do: "bg-[var(--color-bg-2)] text-[var(--color-brand)] border border-[var(--color-brand)]"

  defp env_badge_class(name) do
    lower = String.downcase(name)

    cond do
      String.contains?(lower, "prod") ->
        "bg-[var(--color-success-bg)] text-[var(--color-success-text)] border border-[var(--color-success)]"

      String.contains?(lower, "dev") or String.contains?(lower, "staging") ->
        "bg-[var(--color-info-bg)] text-[var(--color-info-text)] border border-[var(--color-info)]"

      true ->
        "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)] border border-[var(--color-border)]"
    end
  end
end
