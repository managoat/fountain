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
  reserved slug, and nothing else in core changes. The host's own are
  `builtin_slugs/0`; `slugs/0` and `all/0` are the whole registry. Microsoft
  and Slack have moved out (`fountain_microsoft`, `fountain_slack`, ADR 0054
  decision 6): core builds Google alone, and knows the other two only as
  rows an installed extension contributes.

  A platform provider exists whether or not its deployment configured it:
  the providers list always names all of them, with `configured` false until
  the operator sets `<SLUG>_OAUTH_CLIENT_ID` / `_SECRET`, so a client (the
  console, or an app on the API) can render the row as "not available here"
  rather than not knowing the provider could exist.

  What used to be code here — Google's extra authorize parameters, Slack's
  `user_scope` and its `authed_user`-nested token response — is data on the
  struct now (`authorize_params`, `token_body_nest`, #2152), so the OAuth
  client names no service and a provider can come from anywhere, which is
  what let Slack leave.

  One connection per provider covers several products: the Google account
  carries Gmail and Calendar. The granted scopes on the connection say which
  products a tenant actually consented to, and `<SLUG>_OAUTH_SCOPES`
  (space-separated) lets an operator narrow or grow the default request — a
  deployment whose Google app verification does not cover a scope simply
  does not ask for it.
  """

  alias Fountain.Connections.Provider

  @builtin ~w(google)

  @google_scopes ~w(openid email
    https://www.googleapis.com/auth/gmail.modify
    https://www.googleapis.com/auth/calendar)

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
  defp builtin(_), do: nil

  @doc "The env var that configures a platform provider's OAuth client id."
  def client_env_var(%Provider{slug: slug, user_id: nil}),
    do: String.upcase(slug) <> "_OAUTH_CLIENT_ID"

  @doc ~s|"Google" — for "Connect a … account", an extension's too.|
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

  defp scopes(key, default) do
    case Application.get_env(:fountain, key) do
      list when is_list(list) and list != [] -> list
      _ -> default
    end
  end
end
