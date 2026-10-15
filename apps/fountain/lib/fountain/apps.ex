defmodule Fountain.Apps do
  @moduledoc """
  Where the browser apps that sit on Fountain's API live.

  Fountain's own UI is a console — accounts, keys, agents, environments,
  vaults, audit, admin. Watching an agent work is a separate single-page app
  on its own origin, talking to `/api` with a bearer key (ADR 0021 gave it
  "Sign in with Fountain"). This module is the one place that knows its URL,
  so the console's links, an email's "open it" and a forwarded support report
  all agree.

  It defaults to the app hosted on demo.managoat.com, an ordinary static
  build with **no server of its own**: the reader types their Fountain's
  URL in, so the hosted build works against a self-hosted Fountain as soon as
  that server admits the origin:

      API_CORS_ORIGINS=https://fountain-conversations.demo.managoat.com

  A deployment that would rather host its own copy points `CONVERSATIONS_APP_URL`
  at it (and admits *that* origin instead). Setting it to an empty string
  says "this deployment has no such app": the console stops linking to it. Retired browser URLs return the normal 404 response.
  """

  @conversations "https://fountain-conversations.demo.managoat.com/"

  @doc "The conversations app's base URL, or nil where the deployment has none."
  @spec conversations() :: String.t() | nil
  def conversations, do: get(:conversations_app_url, @conversations)

  @doc """
  A deep link into the conversations app, or nil when there is no app.

  The app routes on the fragment, so a conversation is `#/c/<id>` and its raw
  log `#/c/<id>/logs`.

      iex> Fountain.Apps.conversation_url("abc")
      "https://fountain-conversations.demo.managoat.com/#/c/abc"
  """
  @spec conversation_url(String.t(), keyword()) :: String.t() | nil
  def conversation_url(id, opts \\ []) when is_binary(id) do
    case conversations() do
      nil -> nil
      base -> base <> "#/c/" <> id <> if(opts[:logs], do: "/logs", else: "")
    end
  end

  # An unset key takes the default; an explicitly empty one means "none", which
  # is how a deployment turns a link off rather than pointing it somewhere wrong.
  defp get(key, default) do
    case Application.get_env(:fountain, key, default) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> String.trim_trailing(value, "/") <> "/"
    end
  end
end
