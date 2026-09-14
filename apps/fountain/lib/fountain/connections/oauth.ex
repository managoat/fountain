defmodule Fountain.Connections.OAuth do
  @moduledoc """
  The OAuth 2.0 authorization-code client behind every connection (#1186),
  driven by a `Fountain.Connections.Provider`. Since #2152 the client itself
  is `Managoat.McpAuth.Client` in the `managoat_mcp_auth` library, which
  holds the whole client side of MCP authorization (discovery, registration
  and now the flow); this module is the adapter that turns a provider into
  the library's `Managoat.McpAuth.Client.Config` and delegates.

  `to_config/1` is where Fountain's facts become library data. The provider
  must already carry its plaintext `client_secret`
  (`Fountain.Connections.unlock_provider/1`); a platform provider
  (`user_id: nil`) has URLs that are ours, so the library skips the URL
  guard for them (`trusted_urls?`) and insists on a refresh token when the
  access token expires (`require_refresh_token?`) — a tenant provider takes
  what it gets and is checked on every fetch. The Req options and the
  timeout come from `:connections_req_options` and `:connections_timeout_ms`,
  which is how `config/test.exs` points every call at a `Req.Test` plug
  named after this module.

  The return shapes are the library's: `{:ok, grant}` with `refresh_token`,
  `access_token`, `expires_at`, `scopes` and `account_email`;
  `{:error, :invalid_grant}`; `{:error, :no_refresh_token}`;
  `{:error, {:unsafe_url, reason}}`; `{:error, {:http, status, body}}`.
  """

  alias Fountain.Connections.Provider
  alias Managoat.McpAuth.Client
  alias Managoat.McpAuth.Client.Config

  @type grant :: Client.grant()

  @doc "The library config for a provider whose secret is already unlocked."
  @spec to_config(Provider.t()) :: Config.t()
  def to_config(%Provider{} = p) do
    platform? = is_nil(p.user_id)

    Config.new(
      authorize_url: p.authorize_url,
      token_url: p.token_url,
      revoke_url: p.revoke_url,
      userinfo_url: p.userinfo_url,
      account_label_path: p.account_label_path,
      scopes: p.scopes || [],
      client_id: p.client_id,
      client_secret: p.client_secret,
      token_endpoint_auth: p.token_endpoint_auth,
      pkce: p.pkce,
      resource: resource(p),
      authorize_params: p.authorize_params || %{},
      token_body_nest: p.token_body_nest,
      trusted_urls?: platform?,
      require_refresh_token?: platform?,
      receive_timeout: Application.get_env(:fountain, :connections_timeout_ms, 15_000),
      req_options: Application.get_env(:fountain, :connections_req_options, [])
    )
  end

  @doc "The protected resource an `mcp` provider's token is for (RFC 8707)."
  def resource(%Provider{kind: "mcp", mcp_metadata: md, mcp_url: url}),
    do: md["resource"] || url

  def resource(_), do: nil

  @doc "True when the provider has a client Fountain can drive."
  @spec configured?(Provider.t()) :: boolean()
  def configured?(%Provider{} = p), do: Client.configured?(to_config(p))

  @doc "A PKCE code verifier: 43 to 128 unreserved characters (RFC 7636)."
  defdelegate code_verifier, to: Client

  @doc "Where to send the tenant. `verifier` is the PKCE verifier kept in the session, or nil."
  @spec authorize_url(Provider.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def authorize_url(%Provider{} = p, redirect_uri, state, verifier \\ nil),
    do: Client.authorize_url(to_config(p), redirect_uri, state, verifier)

  @doc """
  Exchange the code from the callback for tokens: `{:ok, grant}`. The grant
  has no `refresh_token` when the provider issued none, no `expires_at` when
  it said nothing about expiry, and no `account_email` when the provider
  has no userinfo endpoint — the caller labels the account then.
  """
  @spec exchange_code(Provider.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, grant()} | {:error, term()}
  def exchange_code(%Provider{} = p, code, redirect_uri, verifier \\ nil),
    do: Client.exchange_code(to_config(p), code, redirect_uri, verifier)

  @doc """
  A fresh access token for a refresh token: `{:ok, %{access_token,
  expires_at, refresh_token}}` (the last only when the provider rotated
  it), `{:error, :invalid_grant}` when the provider has forgotten the grant,
  or `{:error, reason}`.
  """
  @spec refresh(Provider.t(), String.t()) :: {:ok, Client.refreshed()} | {:error, term()}
  def refresh(%Provider{} = p, refresh_token), do: Client.refresh(to_config(p), refresh_token)

  @doc """
  Tell the provider to forget the grant (RFC 7009). Best effort: an
  already-revoked token is a 400 there and `:ok` here, because the outcome
  is the same; a provider with no `revoke_url` is `:ok` at once.
  """
  @spec revoke(Provider.t(), String.t()) :: :ok | {:error, term()}
  def revoke(%Provider{} = p, token), do: Client.revoke(to_config(p), token)
end
