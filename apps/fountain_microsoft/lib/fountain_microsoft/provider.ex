defmodule FountainMicrosoft.Provider do
  @moduledoc """
  The Microsoft platform connection provider (#1299, ADR 0033), built from
  this application's configuration (ADR 0054 decision 5).

  One Azure AD app on the `common` endpoint (work and personal accounts), one
  sign-in for Outlook mail, calendar and Teams chat, all on
  `graph.microsoft.com`. Microsoft publishes no OAuth revocation endpoint, so
  revoke is local only.

  The struct has the shape every platform provider has: `user_id: nil`, the
  slug as its id, a plaintext client on the struct and `configured` false
  until the operator sets `MICROSOFT_OAUTH_CLIENT_ID` / `_SECRET`.
  `config/runtime.exs` reads those, and `MICROSOFT_OAUTH_SCOPES`, into
  `config :fountain_microsoft`; nothing in core reads them.
  """

  alias Fountain.Connections.Provider

  @slug "microsoft"

  # `offline_access` is what makes Microsoft issue a refresh token;
  # `User.Read` is what lets `/v1.0/me` name the account. The Teams channel
  # scope (`ChannelMessage.Send`) needs admin consent on work tenants, so the
  # default stops at chats; an operator adds it via MICROSOFT_OAUTH_SCOPES.
  @default_scopes ~w(openid email offline_access User.Read
    Mail.ReadWrite Mail.Send Calendars.ReadWrite Chat.ReadWrite)

  @doc "The reserved slug, `microsoft`."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc "The scopes requested when `MICROSOFT_OAUTH_SCOPES` is unset."
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  @doc """
  The scopes the provider asks for: the operator's `MICROSOFT_OAUTH_SCOPES`
  list when set and non-empty, else `default_scopes/0`.
  """
  @spec scopes() :: [String.t()]
  def scopes do
    case Application.get_env(:fountain_microsoft, :microsoft_oauth_scopes) do
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
      name: "Microsoft (Outlook, Calendar, Teams)",
      kind: "oauth2",
      authorize_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      revoke_url: nil,
      userinfo_url: "https://graph.microsoft.com/v1.0/me",
      account_label_path: "userPrincipalName",
      scopes: scopes(),
      client_id: Application.get_env(:fountain_microsoft, :microsoft_oauth_client_id),
      client_secret: Application.get_env(:fountain_microsoft, :microsoft_oauth_client_secret),
      token_endpoint_auth: "client_secret_post",
      pkce: true,
      env_key: "MICROSOFT_ACCESS_TOKEN",
      token_hosts: ~w(graph.microsoft.com),
      client_source: "manual",
      authorize_params: %{"prompt" => "select_account"}
    }
  end
end
