defmodule Fountain.Conversations.KeyHandover do
  @moduledoc """
  The callback key a turn keeps across a graceful stop (#2835, ADR 0086).

  A deploy stops `ConversationServer` with `:shutdown` while the turn's
  adapter goes on running in the sandbox. That adapter holds the stopping
  server's callback key in its `MANAGOAT_TOKEN` and in the headers of any
  `"auth": "conversation"` MCP server its session was opened with, and
  neither can be replaced in a running process. So the stopping server hands
  the key over instead of revoking it (`CallbackKey.hand_over/2`), and the
  server that reattaches the turn holds it as `handover_callback_key`,
  `{key_id, turn_id}`, until that turn ends, then revokes it
  (`CallbackKey.release_handover/2`).

  Every other stop revokes as before: a crash, any stop with no turn
  running. The key's `expires_at` is the backstop when no server reattaches.
  Only a key the row's handover column names is ever released, never the
  row's live key, which with duplicate servers (#367) can be another
  server's credential.

  Functions over the server's state map, called from `ConversationServer`.
  """

  require Logger

  alias Fountain.Conversations.CallbackKey

  @doc """
  Give back the server's keys as it stops (`terminate/2`).

  A server already driving a handed-over turn passes that key on when the
  turn survives the stop, and gives its own back: the adapter never held its
  own.
  """
  @spec on_stop(term(), map()) :: :ok
  def on_stop(reason, state) do
    turn_survives? = graceful?(reason) and not is_nil(state.current_turn)
    conv_id = state.conversation_id
    own = state.callback_api_key_id

    case state.handover_callback_key do
      {key_id, _turn_id} ->
        _ = CallbackKey.revoke(conv_id, own)
        unless turn_survives?, do: CallbackKey.release_handover(conv_id, key_id)
        :ok

      nil ->
        if turn_survives? and CallbackKey.hand_over(conv_id, own) == :ok,
          do: :ok,
          else: CallbackKey.revoke(conv_id, own)
    end
  rescue
    error ->
      Logger.error(
        "terminate/2: giving back callback keys for conv #{inspect(state.conversation_id)} " <>
          "raised: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp graceful?(:shutdown), do: true
  defp graceful?({:shutdown, _}), do: true
  defp graceful?(_reason), do: false

  @doc """
  The reattach's answer to the handed-over key it read off the row: kept
  while the turn that holds it is back on this server, released at once when
  it is not (no turn was running, it was orphaned, or its prompt is run again
  on a fresh spawn, which takes this server's own key).
  """
  @spec claim(map(), String.t() | nil) :: map()
  def claim(state, nil), do: state

  def claim(%{current_turn: %{id: turn_id}} = state, key_id),
    do: %{state | handover_callback_key: {key_id, turn_id}}

  def claim(state, key_id) do
    CallbackKey.release_handover(state.conversation_id, key_id)
    state
  end

  @doc """
  Revoke the handed-over key once the turn that held it is no longer the one
  this server drives. Called on every path that ends a turn, and before a
  turn starts, so none of them leaves it valid.
  """
  @spec settle(map()) :: map()
  def settle(%{handover_callback_key: {key_id, turn_id}} = state) do
    case state.current_turn do
      %{id: ^turn_id} ->
        state

      _ ->
        CallbackKey.release_handover(state.conversation_id, key_id)
        %{state | handover_callback_key: nil}
    end
  end

  def settle(state), do: state
end
