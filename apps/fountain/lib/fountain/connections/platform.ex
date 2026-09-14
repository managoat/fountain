defmodule Fountain.Connections.Platform do
  @moduledoc """
  The platform connection providers (#1299): the services Fountain owns an
  OAuth client for, so a tenant connects by clicking rather than by
  registering an app. Each is a `Fountain.Connections.Provider` struct built
  from config, `user_id: nil`, with its slug as the reserved id — the same
  shape a tenant row has, so `Fountain.Connections.OAuth` drives every kind
  with one code path.

  The registry is the host's own providers followed by every installed
  extension's (`Fountain.Extension.connection_providers/0`, ADR 0054): a
  connector that ships as an extension is one more row here, one more
  reserved slug, and nothing else in core changes. The host's three are
  `builtin_slugs/0`; `slugs/0` and `all/0` are the whole registry.

  A platform provider exists whether or not its deployment configured it:
  the providers list always names all of them, with `configured` false until
  the operator sets `<SLUG>_OAUTH_CLIENT_ID` / `_SECRET`, so a client (the
  console, or an app on the API) can render the row as "not available here"
  rather than not knowing the provider could exist.

  What used to be code here — Google's extra authorize parameters, Slack's
  `user_scope` and its `authed_user`-nested token response — is data on the
  struct now (`authorize_params`, `token_body_nest`, #2152), so the OAuth
  client names no service and a provider can come from anywhere.

  One connection per provider covers several products: the Google account
  carries Gmail and Calendar, the Microsoft account Outlook mail, calendar
  and Teams chat. The granted scopes on the connection say which products a
  tenant actually consented to, and `<SLUG>_OAUTH_SCOPES` (space-separated)
  lets an operator narrow or grow the default request — a deployment whose
  Google app verification does not cover a scope simply does not ask for it.
  """

  alias Fountain.Connections.Provider

  @builtin ~w(google microsoft slack)

  @google_scopes ~w(openid email
    https://www.googleapis.com/auth/gmail.modify
    https://www.googleapis.com/auth/calendar)

  # `offline_access` is what makes Microsoft issue a refresh token;
  # `User.Read` is what lets `/v1.0/me` name the account. The Teams channel
  # scope (`ChannelMessage.Send`) needs admin consent on work tenants, so the
  # default stops at chats; an operator adds it via MICROSOFT_OAUTH_SCOPES.
  @microsoft_scopes ~w(openid email offline_access User.Read
    Mail.ReadWrite Mail.Send Calendars.ReadWrite Chat.ReadWrite)

  # User-token scopes (sent as `user_scope`): read and post in channels and
  # DMs, and search, as the connected person.
  @slack_scopes ~w(channels:history channels:read chat:write
    im:history im:write users:read search:read)

  @doc "The slugs of the host's own platform providers, in catalog order."
  @spec builtin_slugs() :: [String.t()]
  def builtin_slugs, do: @builtin

  @doc """
  The reserved platform slugs — the host's own and every installed
  extension's. No tenant provider may take one.
  """
  @spec slugs() :: [String.t()]
  def slugs, do: Enum.map(all(), & &1.slug)

  @doc """
  Every platform provider, configured or not: the host's own in catalog
  order, then each installed extension's in configured order.
  """
  @spec all() :: [Provider.t()]
  def all, do: Enum.map(@builtin, &builtin/1) ++ Fountain.Extensions.connection_providers()

  @doc "The platform provider for a slug, the host's or an extension's, or nil."
  @spec get(String.t()) :: Provider.t() | nil
  def get(slug) when is_binary(slug) do
    builtin(slug) ||
      Enum.find(Fountain.Extensions.connection_providers(), &(&1.slug == slug))
  end

  def get(_), do: nil

  defp builtin("google"), do: google()
  defp builtin("microsoft"), do: microsoft()
  defp builtin("slack"), do: slack()
  defp builtin(_), do: nil

  @doc "The env var that configures a platform provider's OAuth client id."
  def client_env_var(%Provider{slug: slug, user_id: nil}),
    do: String.upcase(slug) <> "_OAUTH_CLIENT_ID"

  @doc ~s|"Google", "Microsoft", "Slack" — for "Connect a … account".|
  def short_name(%Provider{slug: slug, user_id: nil}), do: String.capitalize(slug)

  # ── the providers ──────────────────────────────────────────────────────────

  @doc "Google, from `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET`."
  def google do
    %Provider{
      id: "google",
      user_id: nil,
      slug: "google",
      name: "Google (Gmail, Calendar)",
      kind: "oauth2",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      revoke_url: "https://oauth2.googleapis.com/revoke",
      userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
      account_label_path: "email",
      scopes: scopes(:google_oauth_scopes, @google_scopes),
      client_id: Application.get_env(:fountain, :google_oauth_client_id),
      client_secret: Application.get_env(:fountain, :google_oauth_client_secret),
      token_endpoint_auth: "client_secret_post",
      pkce: false,
      env_key: "GOOGLE_ACCESS_TOKEN",
      token_hosts: ~w(gmail.googleapis.com www.googleapis.com),
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

  @doc """
  Microsoft, from `MICROSOFT_OAUTH_CLIENT_ID` / `_SECRET`: one Azure AD app
  on the `common` endpoint (work and personal accounts), one sign-in for
  Outlook mail, calendar and Teams chat, all on `graph.microsoft.com`.
  Microsoft publishes no OAuth revocation endpoint, so revoke is local only.
  """
  def microsoft do
    %Provider{
      id: "microsoft",
      user_id: nil,
      slug: "microsoft",
      name: "Microsoft (Outlook, Calendar, Teams)",
      kind: "oauth2",
      authorize_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      revoke_url: nil,
      userinfo_url: "https://graph.microsoft.com/v1.0/me",
      account_label_path: "userPrincipalName",
      scopes: scopes(:microsoft_oauth_scopes, @microsoft_scopes),
      client_id: Application.get_env(:fountain, :microsoft_oauth_client_id),
      client_secret: Application.get_env(:fountain, :microsoft_oauth_client_secret),
      token_endpoint_auth: "client_secret_post",
      pkce: true,
      env_key: "MICROSOFT_ACCESS_TOKEN",
      token_hosts: ~w(graph.microsoft.com),
      client_source: "manual",
      authorize_params: %{"prompt" => "select_account"}
    }
  end

  @doc """
  Slack, from `SLACK_OAUTH_CLIENT_ID` / `_SECRET`: a user token per
  workspace, brokered to `slack.com`. Slack issues no refresh token unless
  the app opts in to rotation, and no expiry either — the token stands until
  revoked, which the generic client already treats correctly. The account
  label comes from `auth.test` (`user`), so two workspaces where the person
  has the same handle collapse into one connection; reconnecting replaces it.
  """
  def slack do
    scopes = scopes(:slack_oauth_user_scopes, @slack_scopes)

    %Provider{
      id: "slack",
      user_id: nil,
      slug: "slack",
      name: "Slack",
      kind: "oauth2",
      authorize_url: "https://slack.com/oauth/v2/authorize",
      token_url: "https://slack.com/api/oauth.v2.access",
      revoke_url: "https://slack.com/api/auth.revoke",
      userinfo_url: "https://slack.com/api/auth.test",
      account_label_path: "user",
      scopes: scopes,
      client_id: Application.get_env(:fountain, :slack_oauth_client_id),
      client_secret: Application.get_env(:fountain, :slack_oauth_client_secret),
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

  defp scopes(key, default) do
    case Application.get_env(:fountain, key) do
      list when is_list(list) and list != [] -> list
      _ -> default
    end
  end
end
