defmodule FountainWeb.VaultsLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Vaults

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:page_title, "Vaults")
     |> assign(:user_id, user_id)
     |> assign(:filter_search, "")
     |> assign(:vaults, load_vaults(user_id, ""))}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    search = String.trim(search)

    {:noreply,
     socket
     |> assign(:filter_search, search)
     |> assign(:vaults, load_vaults(socket.assigns.user_id, search))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    # Non-bang + nil branch (#401): the list is loaded at mount, so a row
    # deleted from another tab or the API made get_vault! raise and kill
    # the LiveView on the second click.
    case Vaults.get_vault(id, socket.assigns.user_id) do
      nil ->
        {:noreply,
         socket
         |> assign(:vaults, load_vaults(socket.assigns.user_id, socket.assigns.filter_search))
         |> put_flash(:error, "Vault not found — it may already be deleted")}

      vault ->
        flash =
          case Vaults.delete_vault(vault, FountainWeb.Audited.attribution(socket)) do
            {:ok, _} -> {:info, "Deleted #{vault.name}"}
          end

        {:noreply,
         socket
         |> assign(:vaults, load_vaults(socket.assigns.user_id, socket.assigns.filter_search))
         |> put_flash(elem(flash, 0), elem(flash, 1))}
    end
  end

  defp load_vaults(user_id, search) do
    vaults = Vaults.list_vaults_with_counts(user_id)

    if search == "" do
      vaults
    else
      term = String.downcase(search)
      Enum.filter(vaults, fn v -> String.contains?(String.downcase(v.name), term) end)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Vaults</h1>
        <.link navigate={~p"/vaults/new"}>
          <.button>+ New vault</.button>
        </.link>
      </div>

      <p class="text-sm max-w-2xl text-[var(--color-text-muted)]">
        A <strong class="text-[var(--color-text-secondary)]">vault</strong>
        is a bag of env-var overrides — your credentials, a teammate&#39;s, or a virtual identity.
        Pick one when starting a conversation and its values override the environment&#39;s baseline secrets at sprite spawn.
      </p>

      <%!-- Search bar --%>
      <form phx-change="search" phx-submit="search">
        <input
          type="text"
          name="search"
          value={@filter_search}
          phx-debounce="200"
          placeholder="Search vaults…"
          class="w-64 rounded border border-[var(--color-border)] px-3 py-1.5 text-sm focus:outline-none bg-[var(--color-bg-1)] text-[var(--color-text-primary)]"
        />
      </form>

      <%!-- Empty state — no vaults at all --%>
      <div
        :if={@vaults == [] and @filter_search == ""}
        class="rounded-lg p-10 text-center bg-[var(--color-bg-1)] border border-dashed border-[var(--color-border)]"
      >
        <p class="text-sm text-[var(--color-text-muted)]">No vaults yet.</p>
        <p class="text-xs mt-1 text-[var(--color-text-secondary)]">
          Create a vault to store a set of credential overrides you can apply per conversation.
        </p>
      </div>

      <%!-- Empty state — search returned nothing --%>
      <div
        :if={@vaults == [] and @filter_search != ""}
        class="rounded-lg p-8 text-center bg-[var(--color-bg-1)] border border-dashed border-[var(--color-border)]"
      >
        <p class="text-sm text-[var(--color-text-muted)]">
          No vaults match <span class="font-mono text-[var(--color-text-secondary)]">&#34;{@filter_search}&#34;</span>.
        </p>
      </div>

      <%!-- Table --%>
      <table
        :if={@vaults != []}
        class="w-full text-sm rounded-lg overflow-hidden bg-[var(--color-bg-1)] border border-[var(--color-border)]"
      >
        <thead class="border-b border-[var(--color-border)]">
          <tr>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
              Name
            </th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
              Description
            </th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-[var(--color-text-muted)]">
              Secrets
            </th>
            <th class="px-4 py-3"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={v <- @vaults}
            class="border-b border-[var(--color-border)] last:border-0 hover:bg-[var(--color-bg-2)] transition-colors duration-150"
          >
            <td class="px-4 py-3 font-medium text-[var(--color-text-primary)]">{v.name}</td>
            <td class="px-4 py-3 max-w-md">
              <span
                :if={v.description != ""}
                class="text-xs block truncate text-[var(--color-text-muted)]"
                title={v.description}
              >
                {v.description}
              </span>
              <span :if={v.description == ""} class="text-[var(--color-text-muted)]">&#8212;</span>
            </td>
            <td class="px-4 py-3">
              <span
                class={[
                  "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
                  secrets_badge_class(v.secret_count)
                ]}
                title={"#{v.secret_count} secrets"}
              >
                &#128273; {v.secret_count}
              </span>
            </td>
            <td class="px-4 py-3 text-right">
              <div class="inline-flex gap-1">
                <.link navigate={~p"/vaults/#{v.id}/edit"}>
                  <.button variant="secondary">Edit</.button>
                </.link>
                <button
                  class="px-2 py-1 rounded text-xs cursor-pointer bg-[var(--color-error-bg)] border border-[var(--color-error)] text-[var(--color-error-text)] hover:bg-[var(--color-error)] hover:text-white transition-colors"
                  phx-click="delete"
                  phx-value-id={v.id}
                  data-confirm="Delete vault?"
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

  defp secrets_badge_class(0),
    do:
      "bg-[var(--color-bg-2)] text-[var(--color-text-muted)] border border-[var(--color-border)]"

  defp secrets_badge_class(_),
    do:
      "bg-[var(--color-warning-bg)] text-[var(--color-warning-text)] border border-[var(--color-warning)]"
end
