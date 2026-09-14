defmodule Fountain.Connections.Google do
  @moduledoc """
  The Google platform provider's facts (#1178), for the console and the
  catalog. Since #1186 the OAuth flow is `Managoat.McpAuth.Client` behind
  `Fountain.Connections.OAuth`, driven by the `Fountain.Connections.Provider` struct
  `Fountain.Connections.Platform.google/0` builds from config; since #1299
  Google is one platform provider among several, and this module is a thin
  reading of the registry.

  Unset, `configured?/0` is false and the console shows the feature as not
  available on this deployment.
  """

  alias Fountain.Connections.{OAuth, Platform}

  def provider, do: Platform.google()

  def slug, do: "google"
  def scopes, do: provider().scopes
  def token_hosts, do: provider().token_hosts

  @doc "The env var name a Google connection's access token is brokered under."
  def env_key, do: provider().env_key

  @doc "True when both halves of the OAuth client are set."
  def configured?, do: OAuth.configured?(provider())
end
