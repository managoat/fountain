defmodule Fountain.Conversations.ConversationKey do
  @moduledoc """
  The key a turn's `"auth": "conversation"` MCP servers receive (ADR 0086,
  #2934), held by `ConversationServer` as `conversation_key`,
  `{parent_key_id, plaintext}`.

  It is not the sandbox's own `sprite` key. That key reads and drives the
  whole account; this one is `"conversation"`-scoped, and reads its own
  conversation and nothing else (`FountainWeb.Plugs.ConversationKeyScope`).
  It is minted from the callback key the server holds
  (`CallbackKey.mint_conversation_key/3`) the first time a turn's MCP list
  needs it, and only then: a conversation whose agent names no such server
  never has one. The callback key rotates on every provision and reattach;
  the next turn that needs a conversation key then mints a fresh one from
  the new parent. Every path that revokes the callback key revokes this one
  with it (`Accounts.revoke_api_key/3`), so nothing here revokes anything.

  Functions over the server's state map, called from `TurnLaunch`.
  """

  alias Fountain.Conversations.{CallbackKey, McpServers, Redaction}

  @doc """
  The state with a conversation key minted from the current callback key, when
  `agent`'s MCP list for this turn has an `"auth": "conversation"` entry and
  the state holds none for that callback key. Otherwise the state as it was.

  A conversation with no callback key (`sandbox_api_access: "none"`, or a
  mint that failed) gets none, and its servers receive no `Authorization`.
  The plaintext is registered for output redaction, as the callback key is.
  """
  @spec ensure(map(), map() | nil) :: map()
  def ensure(state, agent) do
    parent = state.callback_api_key_id
    agent = McpServers.resolve_for_session(agent, state.resolved_mcp_servers)

    cond do
      not McpServers.conversation_auth?(agent) -> state
      not is_binary(parent) or is_nil(state.callback_token) -> state
      match?({^parent, _}, state.conversation_key) -> state
      true -> mint(state, parent)
    end
  end

  defp mint(state, parent) do
    case CallbackKey.mint_conversation_key(state.conversation_id, state.user_id, parent) do
      {:ok, raw} ->
        Redaction.add(state.conversation_id, [raw])
        %{state | conversation_key: {parent, raw}}

      :error ->
        %{state | conversation_key: nil}
    end
  end

  @doc """
  The plaintext for the session list, when the state holds one minted from
  the callback key it holds now; `nil` otherwise.
  """
  @spec token(map()) :: String.t() | nil
  def token(%{conversation_key: {parent, raw}, callback_api_key_id: parent}), do: raw
  def token(_state), do: nil
end
