defmodule FountainWeb.Live.AccountLive.Connections do
  @moduledoc """
  The Connections section of `/account` (ADR 0085): connect a remote MCP
  server by its URL, reconnect, disconnect.

  Connecting runs discovery and registration (`Fountain.Connections.create/3`)
  and sends the browser to the provider. The provider sends it back to
  `/connections/callback`, which lands here with the outcome as a flash. A
  server that lets no client register itself answers `client_required`, and
  the form then asks for a client the person registered with the provider.
  """
  use FountainWeb, :live_component

  alias Fountain.Connections

  @impl true
  def mount(socket), do: {:ok, assign(socket, needs_client: false, error: nil, url: "")}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     assign_new(socket, :connections, fn -> Connections.list(socket.assigns.current_user.id) end)}
  end

  @impl true
  def handle_event("connect", params, socket) do
    attrs = %{
      "url" => params["url"],
      "client_id" => params["client_id"],
      "client_secret" => params["client_secret"],
      "authorize_params" => authorize_params(params["authorize_params"])
    }

    case Connections.create(socket.assigns.current_user.id, attrs, attribution(socket)) do
      {:ok, _connection, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, :client_required = reason} ->
        {:noreply,
         assign(socket,
           needs_client: true,
           url: params["url"] || "",
           error: Connections.error_message(reason)
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, url: params["url"] || "", error: Connections.error_message(reason))}
    end
  end

  def handle_event("reconnect", %{"id" => id}, socket) do
    case Connections.authorize(socket.assigns.current_user.id, id) do
      {:ok, _connection, url} -> {:noreply, redirect(socket, external: url)}
      {:error, reason} -> {:noreply, assign(socket, :error, Connections.error_message(reason))}
    end
  end

  def handle_event("disconnect", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Connections.delete(user_id, id, attribution(socket)) do
      :ok ->
        send(self(), {:account_flash, :info, "Disconnected"})
        {:noreply, assign(socket, :connections, Connections.list(user_id))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, Connections.error_message(reason))}
    end
  end

  # One `name=value` per line, as Google's `access_type=offline` is written.
  defp authorize_params(text) when is_binary(text) do
    text
    |> String.split(["\n", "&"], trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        [k, v] when k != "" -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      pairs -> Map.new(pairs)
    end
  end

  defp authorize_params(_), do: nil

  defp attribution(socket), do: FountainWeb.Audited.attribution(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="connections-panel" class="space-y-4">
      <div
        :if={@error}
        id="connection-error"
        role="alert"
        class="rounded-lg border border-[var(--color-error)] bg-[var(--color-error-bg)] px-4 py-3 text-sm text-[var(--color-error-text)]"
      >
        {@error}
      </div>

      <form id="connect-mcp-server" phx-submit="connect" phx-target={@myself} class="space-y-3">
        <.form_field
          id="connection-url"
          label="MCP server URL"
          name="url"
          type="url"
          value={@url}
          placeholder="https://mcp.linear.app/mcp"
          errors={[]}
          required
        />

        <div :if={@needs_client} id="connection-client" class="space-y-3">
          <p class="text-xs text-[var(--color-text-muted)]">
            Register an app with the provider, with
            <code class="font-mono">{Connections.redirect_uri()}</code>
            as its redirect URI, and paste its client here.
          </p>
          <.form_field
            id="connection-client-id"
            label="Client ID"
            name="client_id"
            type="text"
            errors={[]}
          />
          <.form_field
            id="connection-client-secret"
            label="Client secret"
            name="client_secret"
            type="password"
            errors={[]}
          />
          <label class="block text-sm text-[var(--color-text-secondary)]">
            Extra authorize parameters, one <code>name=value</code>
            per line <textarea
              id="connection-authorize-params"
              name="authorize_params"
              rows="2"
              placeholder="access_type=offline\nprompt=consent"
              class="mt-1 block w-full rounded border-[var(--color-border-strong)] bg-[var(--color-bg-1)] font-mono text-sm text-[var(--color-text-primary)] shadow-sm"
            ></textarea>
          </label>
        </div>

        <.button type="submit">Connect</.button>
      </form>

      <div
        :if={@connections == []}
        class="rounded border border-dashed border-[var(--color-border)] p-8 text-center text-[var(--color-text-muted)]"
      >
        No connections yet.
      </div>

      <div :if={@connections != []} class="overflow-x-auto">
        <table class="w-full rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] text-sm">
          <thead class="border-b border-[var(--color-border)] text-left text-[var(--color-text-muted)]">
            <tr>
              <th class="px-4 py-2 font-medium">Server</th>
              <th class="px-4 py-2 font-medium">Status</th>
              <th class="px-4 py-2 font-medium">ID</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={c <- @connections}
              id={"connection-#{c.id}"}
              class="border-b border-[var(--color-border)] last:border-0 hover:bg-[var(--color-bg-2)]"
            >
              <td class="break-all px-4 py-2 font-mono text-xs">{c.resource}</td>
              <td class="px-4 py-2 text-xs">
                <span class={[
                  "rounded border px-1.5 py-0.5",
                  if(c.status == "active",
                    do: "border-[var(--color-success)] text-[var(--color-success-text)]",
                    else: "border-[var(--color-error)] text-[var(--color-error-text)]"
                  )
                ]}>
                  {status_label(c.status)}
                </span>
              </td>
              <td class="px-4 py-2 font-mono text-xs text-[var(--color-text-muted)]">{c.id}</td>
              <td class="whitespace-nowrap px-4 py-2 text-right">
                <.button
                  variant="secondary"
                  phx-click="reconnect"
                  phx-target={@myself}
                  phx-value-id={c.id}
                >
                  {if c.status == "pending", do: "Finish connecting", else: "Reconnect"}
                </.button>
                <.button
                  variant="ghost"
                  phx-click="disconnect"
                  phx-target={@myself}
                  phx-value-id={c.id}
                  data-confirm="Disconnect? Agents that name this connection stop reaching the server."
                  class="text-[var(--color-error)] hover:text-[var(--color-error-text)]"
                >
                  Disconnect
                </.button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p class="text-xs text-[var(--color-text-muted)]">
        An agent names a connection in its MCP servers as <code class="font-mono">"auth": &lbrace;"connection": "&lt;id&gt;"&rbrace;</code>.
        The token never enters a sandbox: the egress broker adds it to requests to the server.
      </p>
    </div>
    """
  end

  defp status_label("active"), do: "connected"
  defp status_label("pending"), do: "not finished"
  defp status_label("revoked"), do: "refused by provider"
  defp status_label("expired"), do: "expired"
  defp status_label(other), do: other
end
