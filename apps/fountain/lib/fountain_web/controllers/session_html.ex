defmodule FountainWeb.SessionHTML do
  @moduledoc false
  use FountainWeb, :html

  ## Login form (email + password)

  def new(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 text-zinc-900 font-sans">
      <form
        method="post"
        action={~p"/auth/login"}
        class="w-full max-w-sm bg-white rounded-lg shadow p-8 space-y-4"
      >
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <div>
          <h1 class="text-xl font-semibold">Sign in to {Fountain.Brand.name()}</h1>
          <p class="text-sm text-zinc-500">
            New here?
            <a href={~p"/auth/register"} class="text-zinc-900 underline">Create an account</a>
          </p>
        </div>

        <div :if={@error} class="rounded bg-rose-50 text-rose-700 px-3 py-2 text-sm">{@error}</div>

        <div class="space-y-3">
          <div>
            <label class="block text-sm font-medium text-zinc-700 mb-1">Email</label>
            <input
              type="email"
              name="email"
              placeholder="you@example.com"
              autocomplete="email"
              autofocus
              class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-zinc-700 mb-1">Password</label>
            <input
              type="password"
              name="password"
              placeholder="Password"
              autocomplete="current-password"
              class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
            />
            <div class="flex justify-between mt-1">
              <a
                href={~p"/auth/resend-verification"}
                class="text-xs text-zinc-400 hover:underline"
              >
                Resend verification email
              </a>
              <a href={~p"/auth/forgot-password"} class="text-xs text-zinc-400 hover:underline">
                Forgot password?
              </a>
            </div>
          </div>

          <button
            type="submit"
            class="w-full rounded-md bg-zinc-900 text-white py-2 text-sm font-medium hover:bg-zinc-800"
          >
            Sign in
          </button>

          <div :if={FountainWeb.OAuth.github_configured?()} class="relative flex items-center">
            <div class="flex-grow border-t border-zinc-200"></div>
            <span class="mx-3 text-xs text-zinc-400">or</span>
            <div class="flex-grow border-t border-zinc-200"></div>
          </div>

          <a
            :if={FountainWeb.OAuth.github_configured?()}
            href={~p"/auth/oauth/github"}
            class="flex items-center justify-center gap-2 w-full rounded-md border border-zinc-300 bg-white py-2 text-sm font-medium hover:bg-zinc-50"
          >
            <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
              <path d="M12 0C5.37 0 0 5.37 0 12c0 5.3 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61-.546-1.385-1.335-1.755-1.335-1.755-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 21.795 24 17.295 24 12c0-6.63-5.37-12-12-12" />
            </svg>
            Continue with GitHub
          </a>
        </div>
      </form>
    </div>
    """
  end
end
