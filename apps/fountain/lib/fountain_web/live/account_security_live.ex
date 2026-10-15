defmodule FountainWeb.AccountSecurityLive do
  @moduledoc """
  The /account/security page (#448): change password.

  A LiveView shell for layout consistency, but the form is a plain HTML
  POST to `AccountSecurityController` — see its moduledoc for why (session
  rewrite, rate-limit plug). OAuth-only accounts (no password hash) see an
  explanation instead of the form: without a password there is nothing to
  change.
  """
  use FountainWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Security")
     |> assign(:has_password, not is_nil(user.password_hash))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-8">
      <div>
        <h1 class="text-2xl font-semibold">Security</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Signed in as <span class="font-mono">{@current_user.email}</span>
        </p>
      </div>

      <div
        :if={!@has_password}
        class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-6 shadow-sm text-sm text-[var(--color-text-secondary)]"
      >
        This account signs in with GitHub and has no password, so there is
        nothing to change here. To add a password, use
        <.link navigate={~p"/auth/forgot-password"} class="underline">password reset</.link>
        with your account's email address.
      </div>

      <section
        :if={@has_password}
        class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-6 shadow-sm"
      >
        <h2 class="mb-1 text-lg font-medium">Change password</h2>
        <p class="mb-4 text-sm text-[var(--color-text-secondary)]">
          Every other session is signed out when the password changes; this one stays.
        </p>
        <form
          method="post"
          action={~p"/account/security/password"}
          class="space-y-3"
          id="change-password"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Current password
            </label>
            <input
              type="password"
              name="current_password"
              autocomplete="current-password"
              class="w-full rounded-md border border-[var(--color-border-strong)] bg-[var(--color-bg-1)] px-3 py-2 text-sm"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              New password
            </label>
            <input
              type="password"
              name="new_password"
              placeholder="At least 8 characters"
              autocomplete="new-password"
              class="w-full rounded-md border border-[var(--color-border-strong)] bg-[var(--color-bg-1)] px-3 py-2 text-sm"
            />
          </div>
          <button class="rounded-md bg-zinc-900 text-white px-4 py-2 text-sm font-medium hover:bg-zinc-800">
            Update password
          </button>
        </form>
      </section>
    </div>
    """
  end
end
