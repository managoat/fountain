defmodule FountainWeb.Live.AccountLive do
  @moduledoc """
  `/account` — account deletion.

  Deletion is a core account feature (#479). The handler delegates to
  `Fountain.Accounts.Deletion`.
  """

  use FountainWeb, :live_view

  alias Fountain.Accounts.Deletion

  @impl true
  def mount(_params, _session, socket) do
    socket = FountainWeb.Audited.put_client_ip(socket)

    {:ok,
     assign(socket,
       page_title: "Account",
       delete_confirmation: "",
       deleting: false
     )}
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
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-8 px-4 py-8">
      <h1 class="text-2xl font-semibold">Account</h1>

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
end
