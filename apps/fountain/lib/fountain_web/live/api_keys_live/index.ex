defmodule FountainWeb.ApiKeysLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    keys = Accounts.list_api_keys(user.id)

    {:ok,
     socket
     |> assign(:page_title, "API keys")
     |> assign(:user_id, user.id)
     |> assign(:keys, keys)
     |> assign(:new_key, nil)}
  end

  @impl true
  def handle_event("create_key", %{"label" => label}, socket) do
    # `create_api_key/3` records `api_key.created` itself now, so the
    # `from_socket` call that used to live here would be a second row for one
    # mint. All this surface still owes the trail is who was on the socket.
    case Accounts.create_api_key(
           socket.assigns.user_id,
           label,
           FountainWeb.Audited.attribution(socket)
         ) do
      {:ok, {key, raw_token}} ->
        {:noreply,
         socket
         |> assign(:keys, Accounts.list_api_keys(socket.assigns.user_id))
         |> assign(:new_key, %{key: key, raw_token: raw_token})}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Failed to create API key")}
    end
  end

  def handle_event("dismiss_new_key", _params, socket) do
    {:noreply, assign(socket, :new_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    # `revoke_api_key/3` records `api_key.revoked` itself now (#552), the same
    # move the mint made in #542 — so this surface owes the trail only who was
    # on the socket, and its own `from_socket` call had to go with it.
    case Accounts.revoke_api_key(
           socket.assigns.user_id,
           id,
           FountainWeb.Audited.attribution(socket)
         ) do
      {:ok, _revoked} ->
        {:noreply,
         socket
         |> assign(:keys, Accounts.list_api_keys(socket.assigns.user_id))
         |> put_flash(:info, "Key revoked")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Key not found")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-2xl">
      <div>
        <h1 class="text-2xl font-semibold">API keys</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Use these to authenticate requests to the Fountain API.
          Keys are shown once — copy them immediately.
        </p>
      </div>

      <%!-- New key reveal modal — shown immediately after creation --%>
      <.modal id="new-key-modal" show={@new_key != nil}>
        <:title>New API key created</:title>
        <p class="text-sm text-[var(--color-text-secondary)] mb-4">
          Copy this key now — it won't be shown again.
        </p>
        <div class="flex items-center gap-2">
          <code
            id="new-api-key"
            class="flex-1 bg-[var(--color-bg-2)] rounded border border-[var(--color-border)] px-3 py-2 text-sm font-mono break-all"
          >
            {@new_key && @new_key.raw_token}
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
        <:footer>
          <.button phx-click="dismiss_new_key" variant="secondary">
            I've copied it, dismiss
          </.button>
        </:footer>
      </.modal>

      <%!-- Create new key form --%>
      <form phx-submit="create_key" class="flex gap-2 items-end">
        <div class="flex-1">
          <.form_field
            id="label"
            label="Key label"
            name="label"
            type="text"
            placeholder="e.g. ci-deploy"
            errors={[]}
            required
          />
        </div>
        <.button type="submit">Create key</.button>
      </form>

      <div
        :if={@keys == []}
        class="rounded border border-dashed border-[var(--color-border)] p-8 text-center text-[var(--color-text-muted)]"
      >
        No API keys yet.
      </div>

      <table
        :if={@keys != []}
        class="w-full text-sm bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)]"
      >
        <thead class="text-left text-[var(--color-text-muted)] border-b border-[var(--color-border)]">
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
            </td>
            <td class="px-4 py-2 font-mono text-[var(--color-text-muted)] text-xs">
              {k.key_prefix}···
            </td>
            <td class="px-4 py-2 text-[var(--color-text-muted)] text-xs">
              {format_date(k.inserted_at)}
            </td>
            <td class="px-4 py-2 text-[var(--color-text-muted)] text-xs">
              {if k.last_used_at, do: format_date(k.last_used_at), else: "—"}
            </td>
            <td class="px-4 py-2 text-right">
              <.button
                variant="ghost"
                phx-click="revoke"
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
    """
  end

  defp format_date(nil), do: ""
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")
end
