defmodule FountainSlack.Provider do
  @moduledoc """
  The Slack platform connection provider (#1299, ADR 0033), built from this
  application's configuration (ADR 0054 decision 5).

  A user token per workspace, brokered to `slack.com`. Slack issues no
  refresh token unless the app opts in to rotation, and no expiry either —
  the token stands until revoked, which the generic client already treats
  correctly. The account label comes from `auth.test` (`user`), so two
  workspaces where the person has the same handle collapse into one
  connection; reconnecting replaces it.

  The struct has the shape every platform provider has: `user_id: nil`, the
  slug as its id, a plaintext client on the struct and `configured` false
  until the operator sets `SLACK_OAUTH_CLIENT_ID` / `_SECRET`.
  `config/runtime.exs` reads those, and `SLACK_OAUTH_USER_SCOPES`, into
  `config :fountain_slack`; nothing in core reads them.
  """

  alias Fountain.Connections.Provider

  @slug "slack"

  # User-token scopes (sent as `user_scope`): read and post in channels and
  # DMs, and search, as the connected person.
  @default_scopes ~w(channels:history channels:read chat:write
    im:history im:write users:read search:read)

  @doc "The reserved slug, `slack`."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc "The user scopes requested when `SLACK_OAUTH_USER_SCOPES` is unset."
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  @doc """
  The user scopes the provider asks for: the operator's
  `SLACK_OAUTH_USER_SCOPES` list when set and non-empty, else
  `default_scopes/0`.
  """
  @spec scopes() :: [String.t()]
  def scopes do
    case Application.get_env(:fountain_slack, :slack_oauth_user_scopes) do
      list when is_list(list) and list != [] -> list
      _ -> @default_scopes
    end
  end

  @doc "The provider struct the host lists, reserves and drives."
  @spec provider() :: Provider.t()
  def provider do
    scopes = scopes()

    %Provider{
      id: @slug,
      user_id: nil,
      slug: @slug,
      name: "Slack",
      kind: "oauth2",
      authorize_url: "https://slack.com/oauth/v2/authorize",
      token_url: "https://slack.com/api/oauth.v2.access",
      revoke_url: "https://slack.com/api/auth.revoke",
      userinfo_url: "https://slack.com/api/auth.test",
      account_label_path: "user",
      scopes: scopes,
      client_id: Application.get_env(:fountain_slack, :slack_oauth_client_id),
      client_secret: Application.get_env(:fountain_slack, :slack_oauth_client_secret),
      token_endpoint_auth: "client_secret_post",
      pkce: false,
      env_key: "SLACK_ACCESS_TOKEN",
      token_hosts: ~w(slack.com),
      client_source: "manual",
      # Slack's `scope` parameter requests *bot* scopes; a connection is the
      # person's own account, so the request goes in `user_scope` and `scope`
      # is emptied rather than granting a bot the same names.
      authorize_params: %{"scope" => "", "user_scope" => Enum.join(scopes, " ")},
      # `oauth.v2.access` puts the user token (and, with token rotation on,
      # its refresh token and expiry) under `authed_user`.
      token_body_nest: "authed_user"
    }
  end
end
