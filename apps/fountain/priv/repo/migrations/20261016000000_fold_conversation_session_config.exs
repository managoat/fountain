defmodule Fountain.Repo.Migrations.FoldConversationSessionConfig do
  use Ecto.Migration

  @moduledoc """
  Folds each conversation's own `session_config` into its
  `agent_session_config` (ADR 0062, addendum of 2026-10-15, agent only).

  A conversation's options were the agent's copy from launch, overridden key
  by key by the launch's `session_config`. The conversation layer is removed:
  every turn now requests `agent_session_config` alone. So a running
  conversation launched with options of its own asks for exactly what it
  asked for on the previous release, the merge is written into the one
  column that is read. The harness mode ids are left out, as
  `SessionConfig.effective/1` would drop them anyway.

  `conversations.session_config` is no longer mapped by the schema and is
  dropped one release later. `down/0` is a no-op: the merged values cannot be
  told apart again, and the previous release reads `session_config` over
  `agent_session_config`, which this leaves as it was.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    UPDATE conversations
       SET agent_session_config =
             agent_session_config || (session_config - 'mode' - 'collaboration_mode')
     WHERE session_config <> '{}'::jsonb
    """)
  end

  def down, do: :ok
end
