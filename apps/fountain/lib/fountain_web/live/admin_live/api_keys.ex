defmodule FountainWeb.AdminLive.ApiKeys do
  @moduledoc "Session-protected operator key issuance and revocation. Raw keys live only in component state."
  use FountainWeb, :live_component

  alias Fountain.Accounts

  @impl true
  def mount(socket), do: {:ok, assign(socket, :new_key, nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:admin?, user.role == "admin")
     |> assign_new(:keys, fn -> Accounts.list_api_keys(user.id) end)}
  end

  @impl true
  def handle_event("create_key", %{"label" => label} = params, socket) do
    # `create_api_key/3` records `api_key.created` itself, so all this
    # surface owes the trail is who was on the socket.
    case mint(socket, label, params["admin"] == "true") do
      {:ok, {key, raw_token}} ->
        {:noreply,
         socket
         |> assign(:keys, Accounts.list_api_keys(socket.assigns.current_user.id))
         |> assign(:new_key, %{key: key, raw_token: raw_token})}

      {:error, _cs} ->
        {:noreply, notify(socket, :error, "Failed to create API key")}
    end
  end

  def handle_event("dismiss_new_key", _params, socket) do
    {:noreply, assign(socket, :new_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    # `revoke_api_key/3` records `api_key.revoked` itself (#552).
    user_id = socket.assigns.current_user.id

    case Accounts.revoke_api_key(user_id, id, attribution(socket)) do
      {:ok, _revoked} ->
        {:noreply,
         socket
         |> assign(:keys, Accounts.list_api_keys(user_id))
         |> notify(:info, "Key revoked")}

      {:error, :not_found} ->
        {:noreply, notify(socket, :error, "Key not found")}
    end
  end

  # An admin key (#2660) is the only key `/api/admin` admits. The checkbox is
  # rendered for admins only, and `create_admin_api_key/3` checks the role
  # again, so a forged `admin=true` from anyone else is refused there.
  defp mint(socket, label, true = _admin) do
    Accounts.create_admin_api_key(socket.assigns.current_user, label, attribution(socket))
  end

  defp mint(socket, label, false = _admin) do
    Accounts.create_api_key(socket.assigns.current_user.id, label, attribution(socket))
  end

  # The parent LiveView resolved the client address at mount and passes it
  # in; `Audited.attribution/1` reads it from this socket's assigns.
  defp attribution(socket), do: FountainWeb.Audited.attribution(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="api-keys-panel" class="space-y-4">
      <%!-- The one-time reveal. Inline rather than a modal so it survives the
            section being folded away and reopened before it is copied. --%>
      <div
        :if={@new_key}
        id="new-key-reveal"
        role="status"
        class="rounded-lg border border-[var(--color-success)] bg-[var(--color-success-bg)] p-4"
      >
        <p class="mb-2 text-sm font-medium text-[var(--color-success-text)]">
          New API key created. Copy it now — it won't be shown again.
        </p>
        <div class="flex items-center gap-2">
          <code
            id="new-api-key"
            class="flex-1 break-all rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] px-3 py-2 font-mono text-sm"
          >
            {@new_key.raw_token}
          </code>
          <.button
            phx-hook="CopyToClipboard"
            id="copy-api-key"
            data-target="new-api-key"
            variant="secondary"
          >
            Copy
          </.button>
        </div>
        <div class="mt-3">
          <.button phx-click="dismiss_new_key" phx-target={@myself} variant="secondary">
            I've copied it, dismiss
          </.button>
        </div>
      </div>

      <form
        id="create-api-key"
        phx-submit="create_key"
        phx-target={@myself}
        class="flex items-end gap-2"
      >
        <div class="flex-1">
          <.form_field
            id="api-key-label"
            label="Key label"
            name="label"
            type="text"
            placeholder="e.g. ci-deploy"
            errors={[]}
            required
          />
        </div>
        <label :if={@admin?} class="flex cursor-pointer items-center gap-1.5 pb-2 text-sm">
          <input type="checkbox" id="api-key-admin" name="admin" value="true" class="rounded" />
          Admin key
        </label>
        <.button type="submit">Create key</.button>
      </form>
      <p :if={@admin?} class="text-xs text-[var(--color-text-muted)]">
        Only an admin key can call <code>/api/admin</code>. Keys from sign-in to an app or
        the CLI never can. Give an admin key to one place, such as a provisioner, and nothing else.
      </p>

      <div
        :if={@keys == []}
        class="rounded border border-dashed border-[var(--color-border)] p-8 text-center text-[var(--color-text-muted)]"
      >
        No API keys yet.
      </div>

      <div :if={@keys != []} class="overflow-x-auto">
        <table class="w-full rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] text-sm">
          <thead class="border-b border-[var(--color-border)] text-left text-[var(--color-text-muted)]">
            <tr>
              <th class="px-4 py-2 font-medium">Label</th>
              <th class="px-4 py-2 font-medium">Prefix</th>
              <th class="px-4 py-2 font-medium">Created</th>
              <th class="px-4 py-2 font-medium">Last used</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={k <- @keys}
              class="border-b border-[var(--color-border)] last:border-0 hover:bg-[var(--color-bg-2)]"
            >
              <td class="px-4 py-2 font-medium">
                {k.name}
                <span
                  :if={"admin" in k.scopes}
                  class="ml-1 rounded border border-[var(--color-border)] bg-[var(--color-bg-2)] px-1.5 py-0.5 text-xs font-normal"
                >
                  admin
                </span>
              </td>
              <td class="px-4 py-2 font-mono text-xs text-[var(--color-text-muted)]">
                {k.key_prefix}···
              </td>
              <td class="px-4 py-2 text-xs text-[var(--color-text-muted)]">
                {format_date(k.inserted_at)}
              </td>
              <td class="px-4 py-2 text-xs text-[var(--color-text-muted)]">
                {if k.last_used_at, do: format_date(k.last_used_at), else: "—"}
              </td>
              <td class="px-4 py-2 text-right">
                <.button
                  variant="ghost"
                  phx-click="revoke"
                  phx-target={@myself}
                  phx-value-id={k.id}
                  data-confirm="Revoke this key? Any integrations using it will stop working."
                  class="text-[var(--color-error)] hover:text-[var(--color-error-text)]"
                >
                  Revoke
                </.button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp format_date(nil), do: ""
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  # A component's own flash only reaches the page on navigation, so the
  # message goes to the parent LiveView (this same process) to show.
  defp notify(socket, kind, msg) do
    send(self(), {:account_flash, kind, msg})
    socket
  end
end
