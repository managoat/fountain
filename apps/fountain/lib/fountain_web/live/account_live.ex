defmodule FountainWeb.Live.AccountLive do
  @moduledoc """
  `/account` — data export and account deletion.

  Export and deletion are core account features (#479). The handlers
  delegate to `Fountain.Exports` and `Fountain.Accounts.Deletion`.
  """

  use FountainWeb, :live_view

  alias Fountain.Accounts.Deletion
  alias Fountain.Exports

  @impl true
  def mount(_params, _session, socket) do
    socket = FountainWeb.Audited.put_client_ip(socket)
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Fountain.PubSub, Exports.topic(user.id))
    end

    {:ok,
     assign(socket,
       page_title: "Account",
       delete_confirmation: "",
       deleting: false,
       export: Exports.latest_export(user.id)
     )}
  end

  @impl true
  def handle_event("request_export", _params, socket) do
    user = socket.assigns.current_user

    case Exports.request_export(user, actor: "self", request_ip: socket.assigns[:client_ip]) do
      {:ok, export} ->
        {:noreply,
         socket
         |> assign(:export, export)
         |> put_flash(:info, "Export started — the download will appear here when it is ready.")}

      {:error, {:rate_limited, retry_after}} ->
        minutes = max(div(retry_after + 59, 60), 1)

        {:noreply,
         put_flash(
           socket,
           :error,
           "You can request one export per hour. Try again in about #{minutes} minute(s)."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start the export. Please try again.")}
    end
  end

  @impl true
  def handle_event("confirm_delete_input", %{"email" => email}, socket) do
    {:noreply, assign(socket, :delete_confirmation, email)}
  end

  # Typing the account's own email is the confirmation. It is not a security
  # control — the session already proves who this is — it is a speed bump, so
  # the irreversible button cannot be hit by reflex.
  @impl true
  def handle_event("delete_account", %{"email" => email}, socket) do
    user = socket.assigns.current_user

    cond do
      email != user.email ->
        {:noreply, put_flash(socket, :error, "Type your email address exactly to confirm.")}

      socket.assigns.deleting ->
        {:noreply, socket}

      true ->
        socket = assign(socket, :deleting, true)

        case Deletion.delete_user(user,
               actor: "self",
               request_ip: socket.assigns[:client_ip]
             ) do
          {:ok, _summary} ->
            # Straight out through the controller so the session is dropped;
            # a LiveView cannot clear the session cookie itself.
            {:noreply, redirect(socket, to: ~p"/auth/logout?deleted=1")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:deleting, false)
             |> put_flash(:error, "Account deletion failed. Nothing was deleted.")}
        end
    end
  end

  @impl true
  def handle_info({:export_updated, _user_id}, socket) do
    {:noreply, assign(socket, :export, Exports.latest_export(socket.assigns.current_user.id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-8 px-4 py-8">
      <h1 class="text-2xl font-semibold">Account</h1>

      <%!-- Data export --%>
      <div class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-medium" id="export">Export your data</h2>
        <p class="mb-2 text-sm text-[var(--color-text-secondary)]">
          Download a single JSON file containing your agents, environments, vaults,
          conversations with their full log output, and your audit trail.
        </p>
        <p class="mb-4 text-sm text-[var(--color-text-secondary)]">
          Environment and vault <strong>secret values are deliberately excluded</strong>
          — only secret names are listed. Secrets were write-only on the way in and
          stay that way on the way out.
        </p>

        <%= if @export do %>
          <div class="mb-4 rounded-md bg-[var(--color-bg-2)] p-4 text-sm" id="export-status">
            <%= case export_state(@export) do %>
              <% :pending -> %>
                <span class="text-[var(--color-text-secondary)]">
                  Export requested {Calendar.strftime(@export.inserted_at, "%Y-%m-%d %H:%M UTC")} — generating&hellip; The download will appear here when it is ready.
                </span>
              <% :ready -> %>
                <div class="flex items-center justify-between gap-4">
                  <span class="text-[var(--color-text-secondary)]">
                    Export ready ({format_bytes(@export.byte_size)}) — link expires {Calendar.strftime(
                      @export.expires_at,
                      "%Y-%m-%d %H:%M UTC"
                    )}.
                  </span>
                  <a
                    href={~p"/account/exports/#{@export.id}/download"}
                    class="shrink-0 rounded-md bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-700"
                  >
                    Download
                  </a>
                </div>
              <% :expired -> %>
                <span class="text-[var(--color-text-primary)]">
                  Your last export has expired. Request a new one to download your data.
                </span>
              <% :failed -> %>
                <span class="text-[var(--color-error-text)]">
                  The last export failed. Please request a new one; contact support if it
                  keeps failing.
                </span>
            <% end %>
          </div>
        <% end %>

        <button
          phx-click="request_export"
          class="rounded-md border border-[var(--color-border-strong)] bg-[var(--color-bg-1)] px-4 py-2 text-sm font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)]"
        >
          Request export
        </button>
        <p class="mt-2 text-xs text-[var(--color-text-muted)]">
          One export per hour. Downloads expire after {Exports.ttl_hours()} hours.
        </p>
      </div>

      <%!-- Danger zone --%>
      <div class="rounded-lg border border-red-200 bg-[var(--color-bg-1)] p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-medium text-[var(--color-error-text)]">Delete account</h2>
        <p class="mb-4 text-sm text-[var(--color-text-secondary)]">
          Destroys every running sandbox, and permanently
          deletes your agents, environments, vaults, conversations and stored secrets.
          Secrets are encrypted with a key held only for your account; deleting the
          account destroys that key, so they cannot be recovered afterwards by anyone.
          <strong>This cannot be undone.</strong>
        </p>
        <p class="mb-4 text-sm text-[var(--color-text-secondary)]" id="delete-export-nudge">
          Want a copy of your data first?
          <a href="#export" class="underline">Request an export above</a>
          before deleting — nothing can be recovered afterwards.
        </p>

        <form phx-submit="delete_account" class="space-y-3">
          <label class="block text-sm text-[var(--color-text-secondary)]">
            Type <span class="font-mono font-semibold">{@current_user.email}</span>
            to confirm
            <input
              type="text"
              name="email"
              autocomplete="off"
              value={@delete_confirmation}
              phx-change="confirm_delete_input"
              class="mt-1 block w-full rounded border-[var(--color-border-strong)] bg-[var(--color-bg-1)] text-sm text-[var(--color-text-primary)] shadow-sm"
            />
          </label>

          <button
            type="submit"
            disabled={@delete_confirmation != @current_user.email or @deleting}
            class="rounded bg-red-600 px-4 py-2 text-sm font-medium text-white disabled:cursor-not-allowed disabled:bg-[var(--color-bg-3)]"
          >
            {if @deleting, do: "Deleting…", else: "Delete my account"}
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp export_state(%{status: "pending"}), do: :pending
  defp export_state(%{status: "failed"}), do: :failed

  defp export_state(%{status: "completed"} = export) do
    if Exports.expired?(export), do: :expired, else: :ready
  end

  defp format_bytes(nil), do: "unknown size"
  defp format_bytes(n) when n < 1024, do: "#{n} B"
  defp format_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"
end
