defmodule FountainWeb.PasswordResetHTML do
  @moduledoc false
  use FountainWeb, :html

  def forgot_form(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-surface-0 text-ft-text-primary font-sans">
      <form
        method="post"
        action={~p"/api/auth/forgot"}
        class="w-full max-w-sm bg-surface-1 rounded-lg shadow p-8 space-y-4"
      >
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <div>
          <h1 class="text-xl font-semibold">Reset your password</h1>
          <p class="text-sm text-ft-text-secondary">
            Enter your email and we'll send you a reset link.
          </p>
        </div>
        <input
          type="email"
          name="email"
          placeholder="you@example.com"
          autocomplete="email"
          autofocus
          class="w-full rounded-md border border-ft-border-strong bg-surface-1 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand"
        />
        <button
          type="submit"
          class="w-full rounded-md bg-brand text-white py-2 text-sm font-medium hover:bg-brand-hover"
        >
          Send reset link
        </button>
        <p class="text-center text-sm text-ft-text-secondary">
          <a href={~p"/auth/login"} class="underline">Back to sign in</a>
        </p>
      </form>
    </div>
    """
  end

  def reset_form(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-surface-0 text-ft-text-primary font-sans">
      <form
        method="post"
        action={~p"/auth/reset"}
        class="w-full max-w-sm bg-surface-1 rounded-lg shadow p-8 space-y-4"
      >
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <input type="hidden" name="token" value={@token} />
        <div>
          <h1 class="text-xl font-semibold">Set a new password</h1>
          <p class="text-sm text-ft-text-secondary">Choose a password with at least 8 characters.</p>
        </div>
        <div :if={@error} class="rounded bg-rose-50 text-rose-700 px-3 py-2 text-sm">{@error}</div>
        <input
          type="password"
          name="password"
          placeholder="New password (8+ characters)"
          autocomplete="new-password"
          autofocus
          class="w-full rounded-md border border-ft-border-strong bg-surface-1 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand"
        />
        <button
          type="submit"
          class="w-full rounded-md bg-brand text-white py-2 text-sm font-medium hover:bg-brand-hover"
        >
          Update password
        </button>
      </form>
    </div>
    """
  end
end
