defmodule Fountain.Connections.Platform do
  @moduledoc """
  The platform connection providers (#1299): the services Fountain owns an
  OAuth client for, so a tenant connects by clicking rather than by
  registering an app. Each is a `Fountain.Connections.Provider` struct built
  from config, `user_id: nil`, with its slug as the reserved id — the same
  shape a tenant row has, so the one OAuth client (`Managoat.McpAuth.Client`,
  behind `Fountain.Connections.OAuth`) drives every kind with one code path.

  Since #2152 the registry is entirely what installed extensions contribute
  (`Fountain.Extension.connection_providers/0`, ADR 0054): Google is
  `fountain_google`, Microsoft `fountain_microsoft`, Slack `fountain_slack`,
  and core builds none. A connector that ships as an extension is one more
  row here, one more reserved slug, and nothing else in core changes; a core
  distribution lists exactly what it can connect, which is nothing until an
  extension is installed. `builtin_slugs/0` is empty and kept so the shape
  of the registry reads the same as when core still built one.

  A platform provider exists whether or not its deployment configured it:
  the providers list always names all of them, with `configured` false until
  the operator sets `<SLUG>_OAUTH_CLIENT_ID` / `_SECRET` (read by the
  extension into its own config), so a client (the console, or an app on the
  API) can render the row as "not available here" rather than not knowing
  the provider could exist.

  What used to be code here — Google's extra authorize parameters, Slack's
  `user_scope` and its `authed_user`-nested token response — is data on the
  struct (`authorize_params`, `token_body_nest`, #2152 step 1), so the OAuth
  client names no service and a provider can come from anywhere, which is
  what let all three leave.
  """

  alias Fountain.Connections.Provider

  @doc "The slugs of the host's own platform providers: none since #2152 step 4b."
  @spec builtin_slugs() :: [String.t()]
  def builtin_slugs, do: []

  @doc """
  The reserved platform slugs — every installed extension's. No tenant
  provider may take one.
  """
  @spec slugs() :: [String.t()]
  def slugs, do: Enum.map(all(), & &1.slug)

  @doc """
  Every platform provider, configured or not: each installed extension's, in
  configured order.
  """
  @spec all() :: [Provider.t()]
  def all, do: Fountain.Extensions.connection_providers()

  @doc "The platform provider for a slug, or nil."
  @spec get(String.t()) :: Provider.t() | nil
  def get(slug) when is_binary(slug), do: Enum.find(all(), &(&1.slug == slug))
  def get(_), do: nil

  @doc """
  The env var that configures a platform provider's OAuth client id, by the
  convention ADR 0054 decision 5 sets for every extension.
  """
  def client_env_var(%Provider{slug: slug, user_id: nil}),
    do: String.upcase(slug) <> "_OAUTH_CLIENT_ID"

  @doc ~s|"Google", "Slack" — for "Connect a … account".|
  def short_name(%Provider{slug: slug, user_id: nil}), do: String.capitalize(slug)
end
