defmodule Fountain.Conversations.CallbackKey do
  @moduledoc """
  The per-conversation API key that authenticates the sandbox back to
  Fountain: how long it lives, the options it is minted with, the env pair
  that carries it into the sprite, and the rotation on every fresh provision
  and reattach.

  The plaintext lives only in `ConversationServer` state (`callback_token`)
  and in the sandbox's process env (`Fountain.Conversations.Identity`); the
  durable record is a hash in `api_keys`. `rotate/2` returns the new
  plaintext and row id for the server to hold, with the conversation row
  updated to point at the key. Minting and revoking go through
  `Fountain.Accounts`, which records the audit events (ADR 0013); nothing
  here writes the trail itself.

  Functions over rows and values, not over server state (#1369).
  """

  require Logger

  alias Fountain.{Accounts, Conversations}
  alias Fountain.Conversations.Conversation

  # How long a sprite's callback key stays valid.
  #
  # This is a backstop, not the primary control: the key is revoked at
  # terminate/2 and rotated on every provision and reattach, so under normal
  # operation it is replaced long before expiry. It exists for the hard-crash
  # case, where the row is orphaned and would otherwise be valid forever.
  #
  # The default is deliberately generous. The token is only rotated on provision
  # and reattach, so a TTL shorter than the longest continuously-running
  # conversation would expire a token mid-flight and break the agent's callbacks
  # — a worse failure than a long-lived orphan. Lower it if conversations in your
  # deployment are short.
  @default_ttl_seconds 30 * 24 * 60 * 60

  @spec ttl_seconds() :: non_neg_integer()
  def ttl_seconds do
    Application.get_env(:fountain, :callback_key_ttl_seconds, @default_ttl_seconds)
  end

  # The `x != ""` guards here defend against operator configuration, not against
  # types. Dialyzer proves them always-true from today's success typings —
  # `PublicUrl.base/0` cannot currently return `""` — and flags both the
  # comparison (`exact_compare`) and the `if`'s consequently-dead else branch
  # (`pattern_match`). The guards stay: a future config path that yields an
  # empty base or token must produce no callback env, not a sprite told to call
  # back to `""`.
  #
  # Suppressed here rather than in `.dialyzer_ignore.exs` because that file
  # pins by `{line, column}`, and this function sat near the bottom of a
  # 1400-line module before #1371: the pin moved three times during #540
  # alone, each time failing the build with a misleading "Unnecessary Skips:
  # 1" that reads like a stale suppression rather than "you added lines
  # above". A function-scoped attribute travels with the code it describes
  # and is narrower than the file-wide alternative.
  @dialyzer {:nowarn_function, env: 1}
  @spec env(String.t() | nil) :: [{String.t(), String.t()}]
  def env(token) do
    base = Fountain.PublicUrl.base()

    if is_binary(base) and base != "" and is_binary(token) and token != "" do
      [{"FOUNTAIN_BASE_URL", base}, {"FOUNTAIN_TOKEN", token}]
    else
      []
    end
  end

  @doc """
  Options used when minting a sprite's callback key.

  `"sprite"` scope, not full: the sandbox can stream, prompt and spawn
  sub-agents, but cannot mint a key that would survive the revoke at teardown,
  nor rewrite the agents, environments and vaults a launch is built from.
  The expiry is a backstop for the orphan case — if the BEAM dies hard the row
  is never revoked, and without it the key stays valid forever.

  Public so the scope and expiry can be asserted directly (#192): an unscoped
  callback token is the privilege-escalation path the scoping exists to close.
  `ConversationServer.callback_api_key_opts/0` re-exports it for the tests
  that pin it there.
  """
  @spec api_key_opts() :: keyword()
  def api_key_opts do
    [
      scopes: ["sprite"],
      expires_at:
        DateTime.utc_now()
        |> DateTime.add(ttl_seconds(), :second)
        |> DateTime.truncate(:second),
      # Minting a sprite credential is exactly the event the trail is for, and
      # this is the one mint the account owner did not ask for by hand. Low
      # volume by construction: rotation happens on fresh provision and on
      # wake, not per turn.
      actor: "system:conversation_server"
    ]
  end

  @doc """
  Issue a fresh per-conversation API key scoped to the conversation owner,
  revoking `previous_key_id` — the one THIS server previously minted (a
  re-provision or reattach within one server life) — when there is one.

  A `sandbox_api_access: "none"` conversation never mints a key and returns
  `{:ok, nil, nil, conv}` on every provision and reattach.

  Returns `{:ok, plaintext, key_id, conv}` with the row now pointing at the
  key, or `{:error, conv}` when the mint failed; the caller holds the
  plaintext, since the durable record is a hash in `api_keys` which cannot
  be reversed. That is why the key is rotated on every fresh provision /
  reattach instead of trying to recover the old plaintext.

  Deliberately NOT revoking `conv.callback_api_key_id` when it isn't
  ours: with duplicate servers (registry lag, #367), the row's id can be
  the live credential of the other server's sprite — revoking it 401s
  every callback and sub-agent spawn there, surfaced nowhere. A
  predecessor's un-revoked key goes inert at its `expires_at` and its
  row is pruned by RetentionPruner.
  """
  @spec rotate(Conversation.t(), String.t() | nil) ::
          {:ok, String.t() | nil, String.t() | nil, Conversation.t()}
          | {:error, Conversation.t()}
  def rotate(%Conversation{sandbox_api_access: "none"} = conv, previous_key_id) do
    # No mint occurs, including on provision, wake or reattach. A stale local
    # pointer is revoked defensively; unrelated conversations keep their keys.
    for key_id <- Enum.uniq([previous_key_id, conv.callback_api_key_id]), not is_nil(key_id) do
      Accounts.revoke_api_key(conv.user_id, key_id, actor: "system:conversation_server")
    end

    {:ok, conv} = Conversations.update_conversation(conv, %{callback_api_key_id: nil})
    {:ok, nil, nil, conv}
  end

  def rotate(%Conversation{} = conv, previous_key_id) do
    if previous_key_id do
      _ =
        Accounts.revoke_api_key(conv.user_id, previous_key_id,
          actor: "system:conversation_server"
        )
    end

    case Accounts.create_api_key(
           conv.user_id,
           "sprite:#{String.slice(conv.id, 0, 8)}",
           api_key_opts()
         ) do
      {:ok, {%Accounts.ApiKey{id: key_id}, raw}} ->
        {:ok, conv} = Conversations.update_conversation(conv, %{callback_api_key_id: key_id})
        {:ok, raw, key_id, conv}

      {:error, cs} ->
        Logger.warning(
          "could not issue callback api key for conv #{conv.id}: #{inspect(cs.errors)}"
        )

        {:error, conv}
    end
  end

  @doc """
  Revoke the key a stopping server minted, if the row still names it.

  A server that stops for any reason gives its sprite's callback key back.
  The row check keeps a server that already handed the conversation on from
  revoking its successor's key: reading the row's id at call time made a
  dying duplicate (Horde's CRDT merge mass-terminates losers) revoke the
  SURVIVING server's live credential, and its sprite then 401'd on every
  callback and sub-agent spawn, surfaced nowhere. Best-effort: a key that is
  already gone or inert is not an error.

  If the BEAM dies hard (SIGKILL is untrappable) the `api_keys` row stays, but
  it is not dangerous. `api_key_opts/0` sets an `expires_at`, so an unrevoked
  key stops authenticating on its own and RetentionPruner deletes long-expired
  rows. `SandboxReaper` is the sprite half, which does not self-heal.
  """
  def revoke(conversation_id, key_id) when is_binary(conversation_id) and is_binary(key_id) do
    # ownership: the caller is the conversation's own server, which
    # established ownership before it started. This read only confirms the row
    # still names this key, and attributes the revocation to that owner.
    case Conversations._unsafe_get_conversation(conversation_id) do
      %Conversation{user_id: user_id, callback_api_key_id: ^key_id} when is_binary(user_id) ->
        _ = Accounts.revoke_api_key(user_id, key_id, actor: "system:conversation_server")
        :ok

      _ ->
        :ok
    end
  end

  def revoke(_conversation_id, _key_id), do: :ok
end
