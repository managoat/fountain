defmodule Fountain.Repo.Migrations.AddConversationsDepth do
  @moduledoc """
  Adds `conversations.depth` (#1269, ADR 0083): how many conversations
  started this one, counted up its spawn chain. A conversation started by a
  person or a program outside a sandbox is 0; one started from inside a
  sandbox is the starting conversation's depth plus one, and a start past
  `CONVERSATION_MAX_DEPTH` is refused.

  The column is added with a constant default, which Postgres records in the
  catalog without rewriting the table. Existing rows are then backfilled from
  `parent_conversation_id`, the only lineage the rows recorded before this, so
  a chain already running when the release lands is counted from where it
  really is rather than from 0.

  `down` drops the column; nothing else reads it.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:conversations) do
      add :depth, :integer, null: false, default: 0
    end

    flush()

    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    WITH RECURSIVE chain(id, depth) AS (
      SELECT id, 0 FROM conversations WHERE parent_conversation_id IS NULL
      UNION ALL
      SELECT c.id, chain.depth + 1
      FROM conversations AS c
      INNER JOIN chain ON c.parent_conversation_id = chain.id
      WHERE chain.depth < 1000
    )
    UPDATE conversations AS c
    SET depth = chain.depth
    FROM chain
    WHERE c.id = chain.id AND chain.depth > 0
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:conversations) do
      remove :depth
    end
  end
end
