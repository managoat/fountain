defmodule Fountain.Repo.Migrations.CollapseInferenceCredentialSets do
  use Ecto.Migration

  @moduledoc """
  One inference credential record per user again (ADR 0053's 2026-10-14
  addendum retires named credential sets).

  Every account but one has only ever held one row, its default. An account
  holding more keeps its default and loses the others, with their encrypted
  keys: the default is what every surface that named no set already read.
  An account whose rows somehow include no default has its oldest promoted
  first, so no account that held a key is left with none.

  Agents and conversations that named a deleted row are returned to the
  default by the existing `ON DELETE SET NULL` keys. A conversation whose
  stored inference source was bound to a deleted row is refused with
  `inference_source_changed` at its next turn, as a deleted set always was.

  This release stops reading `name` and `is_default`, so both get the
  defaults its inserts rely on. The columns, the set indexes and the agent and
  conversation pointers stay one release, so a replica of the previous release
  keeps working during the rollout; a later migration drops them and puts the
  unique key on `user_id` back.

  `revision` does not move: its trigger looks only at the four ciphertexts.

  `down/0` restores the column defaults, not the deleted rows.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    UPDATE inference_credentials AS c
       SET is_default = TRUE
     WHERE c.id IN (
       SELECT DISTINCT ON (user_id) id
         FROM inference_credentials
        WHERE user_id NOT IN (SELECT user_id FROM inference_credentials WHERE is_default)
        ORDER BY user_id, inserted_at, id)
    """)

    execute("DELETE FROM inference_credentials WHERE NOT is_default")

    execute("ALTER TABLE inference_credentials ALTER COLUMN name SET DEFAULT 'Default'")
    execute("ALTER TABLE inference_credentials ALTER COLUMN is_default SET DEFAULT TRUE")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE inference_credentials ALTER COLUMN name DROP DEFAULT")
    execute("ALTER TABLE inference_credentials ALTER COLUMN is_default SET DEFAULT FALSE")
  end
end
