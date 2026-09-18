defmodule FountainWeb.RegistrationHTML do
  @moduledoc false
  use FountainWeb, :html

  def new(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 text-zinc-900 font-sans">
      <div class="w-full max-w-sm bg-white rounded-lg shadow p-8 space-y-4">
        <div>
          <h1 class="text-xl font-semibold">Create your account</h1>
          <p class="text-sm text-zinc-500">
            Already have an account?
            <a href={~p"/auth/login"} class="text-zinc-900 underline">Sign in</a>
          </p>
        </div>

        <div
          :if={Phoenix.Flash.get(@flash, :error)}
          class="rounded bg-rose-50 text-rose-700 px-3 py-2 text-sm"
        >
          {Phoenix.Flash.get(@flash, :error)}
        </div>

        <form method="post" action={~p"/auth/register"} class="space-y-3">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />

          <div :if={Fountain.Accounts.access_code_required?()}>
            <label class="block text-sm font-medium text-zinc-700 mb-1">Access code</label>
            <input
              type="text"
              name="user[access_code]"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
            />
            <div :if={@errors[:access_code]} class="mt-1 text-xs text-rose-600">
              {Enum.join(@errors[:access_code], ", ")}
            </div>
          </div>

          <div>
            <label class="block text-sm font-medium text-zinc-700 mb-1">Email</label>
            <input
              type="email"
              name="user[email]"
              placeholder="you@example.com"
              autocomplete="email"
              autofocus
              class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
            />
            <div :if={@errors[:email]} class="mt-1 text-xs text-rose-600">
              {Enum.join(@errors[:email], ", ")}
            </div>
          </div>

          <div>
            <label class="block text-sm font-medium text-zinc-700 mb-1">Password</label>
            <input
              type="password"
              name="user[password]"
              placeholder="At least 8 characters"
              autocomplete="new-password"
              class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
            />
            <div :if={@errors[:password]} class="mt-1 text-xs text-rose-600">
              {Enum.join(@errors[:password], ", ")}
            </div>
          </div>

          <button
            type="submit"
            class="w-full rounded-md bg-zinc-900 text-white py-2 text-sm font-medium hover:bg-zinc-800"
          >
            Create account
          </button>

          <%!-- With an access code, GitHub signup submits this form so the code
               goes with it; RegistrationController.oauth/2 carries it through
               the OAuth round trip. The plain link below would lose it. --%>
          <button
            :if={Fountain.Accounts.access_code_required?() and FountainWeb.OAuth.github_configured?()}
            type="submit"
            formaction={~p"/auth/register/github"}
            formnovalidate
            class="flex items-center justify-center gap-2 w-full rounded-md border border-zinc-300 bg-white py-2 text-sm font-medium hover:bg-zinc-50"
          >
            <.github_mark /> Sign up with GitHub
          </button>
        </form>

        <div
          :if={
            FountainWeb.OAuth.github_configured?() and not Fountain.Accounts.access_code_required?()
          }
          class="relative flex items-center"
        >
          <div class="flex-grow border-t border-zinc-200"></div>
          <span class="mx-3 text-xs text-zinc-400">or</span>
          <div class="flex-grow border-t border-zinc-200"></div>
        </div>

        <a
          :if={
            FountainWeb.OAuth.github_configured?() and not Fountain.Accounts.access_code_required?()
          }
          href={~p"/auth/oauth/github"}
          class="flex items-center justify-center gap-2 w-full rounded-md border border-zinc-300 bg-white py-2 text-sm font-medium hover:bg-zinc-50"
        >
          <.github_mark /> Sign up with GitHub
        </a>

        <p :if={Fountain.Legal.published?()} class="text-xs text-zinc-400 text-center">
          By signing up you agree to our <a href={~p"/terms"} class="underline">terms of service</a>
          and <a href={~p"/privacy"} class="underline">privacy policy</a>.
        </p>
      </div>
    </div>
    """
  end

  defp github_mark(assigns) do
    ~H"""
    <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
      <path d="M12 0C5.37 0 0 5.37 0 12c0 5.3 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61-.546-1.385-1.335-1.755-1.335-1.755-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 21.795 24 17.295 24 12c0-6.63-5.37-12-12-12" />
    </svg>
    """
  end

  def check_email(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 text-zinc-900 font-sans">
      <div class="w-full max-w-sm bg-white rounded-lg shadow p-8 space-y-4 text-center">
        <h1 class="text-xl font-semibold">Check your email</h1>
        <p class="text-sm text-zinc-600">
          We sent a verification link to your email address.
          Click the link to activate your account.
        </p>
        <p class="text-xs text-zinc-400">
          Didn't receive it? Check your spam folder or <a
            href={~p"/auth/resend-verification"}
            class="underline"
          >resend the email</a>.
        </p>
      </div>
    </div>
    """
  end

  def resend_form(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 text-zinc-900 font-sans">
      <form
        method="post"
        action={~p"/auth/resend-verification"}
        class="w-full max-w-sm bg-white rounded-lg shadow p-8 space-y-4"
      >
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <div>
          <h1 class="text-xl font-semibold">Resend verification email</h1>
          <p class="text-sm text-zinc-500">
            Enter your email and we'll send a fresh verification link. Links
            expire after 24 hours.
          </p>
        </div>
        <input
          type="email"
          name="email"
          placeholder="you@example.com"
          autocomplete="email"
          autofocus
          class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
        />
        <button
          type="submit"
          class="w-full rounded-md bg-zinc-900 text-white py-2 text-sm font-medium hover:bg-zinc-800"
        >
          Send verification link
        </button>
        <p class="text-center text-sm text-zinc-400">
          <a href={~p"/auth/login"} class="underline">Back to sign in</a>
        </p>
      </form>
    </div>
    """
  end
end
