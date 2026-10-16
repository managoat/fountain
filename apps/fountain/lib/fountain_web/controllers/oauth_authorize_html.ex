defmodule FountainWeb.OAuthAuthorizeHTML do
  @moduledoc false
  use FountainWeb, :html

  def consent(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-surface-0 text-ft-text-primary font-sans">
      <form
        method="post"
        action={~p"/oauth/authorize"}
        class="w-full max-w-sm bg-surface-1 rounded-lg shadow p-8 space-y-5"
      >
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <input :for={{k, v} <- @params} type="hidden" name={k} value={v} />
        <div class="space-y-1">
          <div class="text-xs uppercase tracking-wide text-ft-text-secondary">Managoat</div>
          <h1 class="text-xl font-semibold">Sign in to {@client.name}?</h1>
          <p :if={not @client.published} class="text-xs text-amber-700 bg-amber-50 rounded px-2 py-1">
            <span class="font-medium">In development.</span>
            You registered this app yourself, and it signs in nobody but you. Nothing here has been
            reviewed, so read the address it returns to before you allow it.
          </p>
          <p class="text-sm text-ft-text-secondary">
            <span class="font-medium">{@client.name}</span>
            is asking to use your Managoat account. Allowing it issues an API key it will use to
            act as you — start conversations, run agents, read your environments and vaults. You can
            revoke it any time under <a href={Fountain.Apps.account_url("api-keys")} class="underline">Account → API keys</a>.
          </p>
          <p class="text-xs text-ft-text-secondary font-mono break-all">
            Signed in as {@current_user.email} · returns to {@params["redirect_uri"]}
          </p>
        </div>
        <div class="flex gap-2 justify-end">
          <button
            type="submit"
            name="decision"
            value="deny"
            class="rounded-md border border-ft-border-strong px-4 py-2 text-sm hover:bg-surface-0"
          >
            Deny
          </button>
          <button
            type="submit"
            name="decision"
            value="allow"
            class="rounded-md bg-brand text-white px-4 py-2 text-sm font-medium hover:bg-brand-hover"
          >
            Allow
          </button>
        </div>
      </form>
    </div>
    """
  end

  def invalid(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-surface-0 text-ft-text-primary font-sans">
      <div class="w-full max-w-sm bg-surface-1 rounded-lg shadow p-8 space-y-3">
        <h1 class="text-xl font-semibold">That sign-in request is not valid</h1>
        <p class="text-sm text-ft-text-secondary">{reason_text(@reason)}</p>
        <p class="text-xs text-ft-text-secondary">
          Nothing was authorized. If you got here from an app, tell whoever runs it; if you run it,
          check its OAuth client registration on this Managoat.
        </p>
      </div>
    </div>
    """
  end

  defp reason_text(:unknown_client),
    do: "The app is not registered with this Managoat (unknown client_id)."

  defp reason_text(:development_mode),
    do:
      "This app is in development. Only the account that registered it can sign in, " <>
        "and that is not the account you are signed in as."

  defp reason_text(:redirect_uri_mismatch),
    do: "The app asked to send you somewhere it is not registered for (redirect_uri)."

  defp reason_text(:invalid_code_challenge),
    do: "The request is missing a valid PKCE code challenge."

  defp reason_text(:unsupported_code_challenge_method),
    do: "Only the S256 code challenge method is supported."

  defp reason_text(_), do: "Something went wrong issuing the code. Try again."
end
