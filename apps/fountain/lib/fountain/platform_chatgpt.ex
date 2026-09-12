defmodule Fountain.PlatformChatGPT do
  @moduledoc """
  Compatibility API for the deployment's ChatGPT account (ADR 0047).

  Admin callers and the existing refresher keep this interface. Shared grant
  storage lives in `Fountain.ChatGPTAccounts`; every delegation here selects
  platform ownership explicitly and cannot read a user's grant.
  """

  alias Fountain.ChatGPTAccounts

  defdelegate active?(), to: ChatGPTAccounts, as: :_unsafe_platform_active?
  defdelegate credential(opts \\ []), to: ChatGPTAccounts, as: :_unsafe_platform_credential
  defdelegate access_token(), to: ChatGPTAccounts, as: :_unsafe_platform_access_token
  defdelegate sandbox_auth(), to: ChatGPTAccounts, as: :_unsafe_platform_sandbox_auth
  defdelegate status(), to: ChatGPTAccounts, as: :_unsafe_platform_status

  defdelegate connect_from_auth_json(json, opts \\ []),
    to: ChatGPTAccounts,
    as: :_unsafe_platform_connect_from_auth_json

  defdelegate connect_from_tokens(tokens, method, opts \\ []),
    to: ChatGPTAccounts,
    as: :_unsafe_platform_connect_from_tokens

  defdelegate connect_workspace_token(token, expires_on, opts \\ []),
    to: ChatGPTAccounts,
    as: :_unsafe_platform_connect_workspace_token

  defdelegate disconnect(opts \\ []), to: ChatGPTAccounts, as: :_unsafe_platform_disconnect
  defdelegate keepalive(), to: ChatGPTAccounts, as: :_unsafe_platform_keepalive

  defdelegate refresh_serialized(mode),
    to: ChatGPTAccounts,
    as: :_unsafe_platform_refresh_serialized

  defdelegate refresh_margin_seconds(),
    to: ChatGPTAccounts,
    as: :_unsafe_platform_refresh_margin_seconds

  defdelegate keepalive_days(), to: ChatGPTAccounts, as: :_unsafe_platform_keepalive_days
end
