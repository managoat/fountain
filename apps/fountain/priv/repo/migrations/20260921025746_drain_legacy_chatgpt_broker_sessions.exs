defmodule Fountain.Repo.Migrations.DrainLegacyChatgptBrokerSessions do
  use Ecto.Migration

  # ADR 0052 decision 5: "invalidate and drain legacy managed-grant sessions
  # ... no old socket is grandfathered into the HTTP-only path."
  #
  # Until this release a codex conversation on the deployment's ChatGPT grant
  # carried the grant's bearer inside its broker session, as a `substitute`
  # rule in `rules_ciphertext`: exportable to a custom binding's template,
  # checked against nothing per request, and free to upgrade to a WebSocket.
  # From this release such a conversation's session records which grant it may
  # use and holds no bearer (`20260921021249`). The old rows have to go, or a
  # process still holding one of their tokens keeps the old path for up to the
  # session's six hours.
  #
  # Which rows: every session with no managed grant recorded whose
  # conversation is bound to the ChatGPT credential. Only the deployment's
  # grant ever had such a session; a user's grant has never had one of the
  # old kind.
  #
  # What it costs: a codex turn on the grant that is in flight across the
  # upgrade loses its proxy session and fails at its next request with a 407.
  # Every conversation server mints a new session when it starts, which it
  # does on the upgraded release, so the next turn runs.
  #
  # What it cannot do: stop a replica still running the previous release from
  # minting another such session after this has run. Roll every replica; a
  # straggler's session is gone at its expiry, and nothing renews the bearer
  # inside it.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    DELETE FROM broker_sessions s
    USING conversations c
    WHERE c.id = s.conversation_id
      AND c.inference_source->>'kind' = 'codex_chatgpt_access_token'
      AND s.managed_grant_id IS NULL
    """)
  end

  # Nothing to restore: a deleted session is re-minted, not recovered.
  def down, do: :ok
end
