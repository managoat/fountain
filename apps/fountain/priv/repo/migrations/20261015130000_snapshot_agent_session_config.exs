defmodule Fountain.Repo.Migrations.SnapshotAgentSessionConfig do
  use Ecto.Migration

  # ADR 0062, addendum of 2026-10-15 (#2664): a conversation keeps the agent's
  # session_config as it was at launch, in `conversations.agent_session_config`,
  # instead of reading the agent's on every turn. An edit to the agent then
  # reaches new conversations only.
  #
  # The backfill copies each conversation's agent's current session_config, so
  # an existing conversation's next turn asks for exactly what it would have
  # asked for on the previous release: nothing changes mid-run. For a
  # conversation that has already ended, the copy is the agent's config at
  # migration time, not at its launch; the request each turn actually sent is
  # on `turns.config_selection["requested"]`. A conversation whose agent is
  # gone keeps the empty map, which is what the previous release read for it.
  #
  # The harness mode ids ADR 0062's first 2026-10-14 addendum refused are left
  # out of the copy, as `SessionConfig.effective/2` would drop them anyway.
  #
  # The column add has a constant default, so it is metadata-only; the lock is
  # still ACCESS EXCLUSIVE on a table every turn reads, so give up after five
  # seconds rather than queue behind a reader. The backfill is one UPDATE over
  # the rows that have an agent.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:conversations) do
      add :agent_session_config, :map, null: false, default: %{}
    end

    flush()

    execute("""
    UPDATE conversations AS c
       SET agent_session_config = a.session_config - 'mode' - 'collaboration_mode'
      FROM agents AS a
     WHERE c.agent_id = a.id
       AND a.session_config <> '{}'::jsonb
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:conversations) do
      remove :agent_session_config
    end
  end
end
