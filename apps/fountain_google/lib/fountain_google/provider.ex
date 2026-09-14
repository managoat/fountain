defmodule FountainGoogle.Provider do
  @moduledoc """
  The Google platform connection provider (#1178, #1299, ADR 0033), built
  from this application's configuration (ADR 0054 decision 5).

  One Google account covers Gmail and Calendar; the granted scopes on the
  connection say which products a tenant actually consented to, and
  `GOOGLE_OAUTH_SCOPES` lets an operator narrow or grow the default request,
  because a deployment whose Google app verification does not cover a scope
  simply does not ask for it. The token is brokered under
  `GOOGLE_ACCESS_TOKEN` to the two Google API hosts, which is how the Gmail
  MCP server this extension also serves reaches the API.

  The struct has the shape every platform provider has: `user_id: nil`, the
  slug as its id, a plaintext client on the struct and `configured` false
  until the operator sets `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET`.
  `config/runtime.exs` reads those, and `GOOGLE_OAUTH_SCOPES`, into
  `config :fountain_google`; nothing in core reads them.
  """

  alias Fountain.Connections.Provider

  @slug "google"

  @default_scopes ~w(openid email
    https://www.googleapis.com/auth/gmail.modify
    https://www.googleapis.com/auth/calendar)

  @token_hosts ~w(gmail.googleapis.com www.googleapis.com)

  @doc "The reserved slug, `google`."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc "The scopes requested when `GOOGLE_OAUTH_SCOPES` is unset."
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  @doc "The hosts a Google token is brokered to: Gmail and the shared API host (calendar/v3)."
  @spec token_hosts() :: [String.t()]
  def token_hosts, do: @token_hosts

  @doc "The env var name a Google connection's access token is brokered under."
  @spec env_key() :: String.t()
  def env_key, do: "GOOGLE_ACCESS_TOKEN"

  @doc """
  The scopes the provider asks for: the operator's `GOOGLE_OAUTH_SCOPES`
  list when set and non-empty, else `default_scopes/0`.
  """
  @spec scopes() :: [String.t()]
  def scopes do
    case Application.get_env(:fountain_google, :google_oauth_scopes) do
      list when is_list(list) and list != [] -> list
      _ -> @default_scopes
    end
  end

  @doc "The provider struct the host lists, reserves and drives."
  @spec provider() :: Provider.t()
  def provider do
    %Provider{
      id: @slug,
      user_id: nil,
      slug: @slug,
      name: "Google (Gmail, Calendar)",
      kind: "oauth2",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      revoke_url: "https://oauth2.googleapis.com/revoke",
      userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
      account_label_path: "email",
      scopes: scopes(),
      client_id: Application.get_env(:fountain_google, :google_oauth_client_id),
      client_secret: Application.get_env(:fountain_google, :google_oauth_client_secret),
      token_endpoint_auth: "client_secret_post",
      pkce: false,
      env_key: env_key(),
      token_hosts: @token_hosts,
      client_source: "manual",
      # Without `access_type=offline` + `prompt=consent`, Google returns no
      # refresh token on a second consent, and a connection with no refresh
      # token is dead in an hour. `include_granted_scopes` is what makes a
      # reconnect after a scope was added incremental rather than a reset.
      authorize_params: %{
        "access_type" => "offline",
        "prompt" => "consent",
        "include_granted_scopes" => "true"
      }
    }
  end
end
