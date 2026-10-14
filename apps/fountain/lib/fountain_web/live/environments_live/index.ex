defmodule FountainWeb.EnvironmentsLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Environments

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:page_title, "Environments")
     |> assign(:user_id, user_id)
     |> assign(:filter_search, "")
     |> assign(:envs, load_envs(user_id, ""))}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    search = String.trim(search)

    {:noreply,
     socket
     |> assign(:filter_search, search)
     |> assign(:envs, load_envs(socket.assigns.user_id, search))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    # Non-bang + nil branch (#401): the list is loaded at mount, so a row
    # deleted from another tab or the API made get_environment! raise and
    # kill the LiveView on the second click.
    case Environments.get_environment(id, socket.assigns.user_id) do
      nil ->
        {:noreply,
         socket
         |> assign(:envs, load_envs(socket.assigns.user_id, socket.assigns.filter_search))
         |> put_flash(:error, "Environment not found — it may already be deleted")}

      env ->
        flash =
          case Environments.delete_environment(env, FountainWeb.Audited.attribution(socket)) do
            {:ok, _} -> {:info, "Deleted #{env.name}"}
          end

        {:noreply,
         socket
         |> assign(:envs, load_envs(socket.assigns.user_id, socket.assigns.filter_search))
         |> put_flash(elem(flash, 0), elem(flash, 1))}
    end
  end

  defp load_envs(user_id, search) do
    envs = Environments.list_environments_with_counts(user_id)

    if search == "" do
      envs
    else
      term = String.downcase(search)
      Enum.filter(envs, fn e -> String.contains?(String.downcase(e.name), term) end)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Environments</h1>
        <.link navigate={~p"/environments/new"}>
          <.button>+ New environment</.button>
        </.link>
      </div>

      <%!-- Search bar --%>
      <form phx-change="search" phx-submit="search">
        <input
          type="text"
          name="search"
          value={@filter_search}
          phx-debounce="200"
          placeholder="Search environments…"
          class="w-64 rounded border border-[var(--color-border)] px-3 py-1.5 text-sm focus:outline-none bg-[var(--color-bg-1)] text-[var(--color-text-primary)]"
        />
      </form>

      <%!-- Empty state — no envs at all --%>
      <div
        :if={@envs == [] and @filter_search == ""}
        class="rounded-lg p-10 text-center bg-[var(--color-bg-1)] border border-dashed border-[var(--color-border)]"
      >
        <p class="text-sm text-[var(--color-text-muted)]">No environments yet.</p>
        <p class="text-xs mt-1 text-[var(--color-text-secondary)]">
          Create one to configure packages, secrets, and a setup script for your agents.
        </p>
      </div>

      <%!-- Empty state — search returned nothing --%>
      <div
        :if={@envs == [] and @filter_search != ""}
        class="rounded-lg p-8 text-center bg-[var(--color-bg-1)] border border-dashed border-[var(--color-border)]"
      >
        <p class="text-sm text-[var(--color-text-muted)]">
          No environments match <span class="font-mono text-[var(--color-text-secondary)]">&#34;{@filter_search}&#34;</span>.
        </p>
      </div>

      <%!-- Table --%>
      <table
        :if={@envs != []}
        class="w-full text-sm rounded-lg overflow-hidden bg-[var(--color-bg-1)] border border-[var(--color-border)]"
      >
        <thead class="border-b border-[var(--color-border)]">
          <tr>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
              Name
            </th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
              Network
            </th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
              Setup
            </th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
              Stats
            </th>
            <th class="px-4 py-3"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={e <- @envs}
            class="border-b border-[var(--color-border)] last:border-0 hover:bg-[var(--color-bg-2)] transition-colors duration-150"
          >
            <td class="px-4 py-3 font-medium text-[var(--color-text-primary)]">{e.name}</td>
            <td class="px-4 py-3">
              <span class={[
                "inline-flex items-center gap-1 px-2 py-1 rounded text-xs font-semibold",
                networking_badge_class(e.networking_type)
              ]}>
                <span class="w-1.5 h-1.5 rounded-full" style="background:currentColor;"></span>
                {e.networking_type}
              </span>
            </td>
            <td class="px-4 py-3">
              <span
                :if={e.setup_script != ""}
                class="font-mono text-xs block truncate max-w-xs text-[var(--color-text-muted)]"
                title={e.setup_script}
              >
                {truncate(e.setup_script, 48)}
              </span>
              <span :if={e.setup_script == ""} class="text-[var(--color-text-muted)]">&#8212;</span>
            </td>
            <td class="px-4 py-3">
              <div class="flex items-center gap-1.5 flex-wrap">
                <span
                  class={[
                    "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
                    stat_badge_class(:secrets, e.secret_count)
                  ]}
                  title={"#{e.secret_count} secrets"}
                >
                  &#128273; {e.secret_count}
                </span>
                <span
                  class={[
                    "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
                    stat_badge_class(:agents, e.agent_count)
                  ]}
                  title={"#{e.agent_count} agents"}
                >
                  &#9889; {e.agent_count}
                </span>
                <span
                  :if={map_size(e.packages) > 0}
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-[var(--color-bg-2)] text-[var(--color-brand)] border border-[var(--color-brand)]"
                  title={"#{map_size(e.packages)} packages"}
                >
                  &#128230; {map_size(e.packages)}
                </span>
                <span
                  :if={length(e.repositories) > 0}
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-[var(--color-info-bg)] text-[var(--color-info-text)] border border-[var(--color-info)]"
                  title={"#{length(e.repositories)} repos"}
                >
                  &#9322; {length(e.repositories)}
                </span>
              </div>
            </td>
            <td class="px-4 py-3 text-right">
              <div class="inline-flex gap-1">
                <.link navigate={~p"/environments/#{e.id}/edit"}>
                  <.button variant="secondary">Edit</.button>
                </.link>
                <button
                  class="px-2 py-1 rounded text-xs cursor-pointer bg-[var(--color-error-bg)] border border-[var(--color-error)] text-[var(--color-error-text)] hover:bg-[var(--color-error)] hover:text-white transition-colors"
                  phx-click="delete"
                  phx-value-id={e.id}
                  data-confirm="Delete environment?"
                >
                  Delete
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: binary_part(str, 0, max) <> "…"

  defp networking_badge_class("unrestricted"),
    do:
      "bg-[var(--color-success-bg)] text-[var(--color-success-text)] border border-[var(--color-success)]"

  defp networking_badge_class("limited"),
    do:
      "bg-[var(--color-warning-bg)] text-[var(--color-warning-text)] border border-[var(--color-warning)]"

  defp networking_badge_class(_),
    do:
      "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)] border border-[var(--color-border)]"

  defp stat_badge_class(_type, 0),
    do:
      "bg-[var(--color-bg-2)] text-[var(--color-text-muted)] border border-[var(--color-border)]"

  defp stat_badge_class(:secrets, _),
    do:
      "bg-[var(--color-warning-bg)] text-[var(--color-warning-text)] border border-[var(--color-warning)]"

  defp stat_badge_class(:agents, _),
    do:
      "bg-[var(--color-success-bg)] text-[var(--color-success-text)] border border-[var(--color-success)]"
end
