defmodule Fountain.Repo.Migrations.FlattenSandboxAppliedSkills do
  @moduledoc """
  The skills record goes back to one list per machine:
  `sandboxes.applied_skills`, beside `applied_skills_by_runtime`.

  `applied_skills_by_runtime` (`20260926150000`, #2514) keyed the record by
  runtime because a machine could host conversations of two runtimes. Since
  ADR 0073 a machine carries one conversation, so one runtime, and the key
  carries nothing.

  **Backfilled from the entry of the runtime of the machine's newest
  conversation.** `sandboxes.runtime` is gone (`20261014191000`), so the
  conversation is the only evidence; it is the same evidence
  `20260926150000` fell back to. A row whose map has no entry for that
  runtime gets no record: an entry for another runtime describes another
  skills root, and `nil` makes the next reconciliation fall back to the
  conversation's Agent version, as it already does on such a row.

  **The old column stays for a release.** This release stops reading and
  writing it; `20261016150001_drop_sandbox_applied_skills_by_runtime`, in a
  later release, drops it. A rollback to the previous release reads the map
  as this migration found it: a reconciliation this release recorded is not
  in it, so that rollback can at worst leave on the disk a skill this
  release installed and the agent has since dropped.

  `down/0` drops the new column; the map is unchanged by `up/0`.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:sandboxes) do
      add :applied_skills, {:array, :map}
    end

    flush()

    execute("""
    UPDATE sandboxes AS s
    SET applied_skills = ARRAY(
      SELECT jsonb_array_elements(s.applied_skills_by_runtime -> latest.runtime)
    )
    FROM sandboxes AS s2
    CROSS JOIN LATERAL (
      SELECT c.runtime
      FROM conversations AS c
      WHERE c.sandbox_id = s2.id AND c.user_id = s2.user_id
      ORDER BY c.inserted_at DESC, c.id DESC
      LIMIT 1
    ) AS latest
    WHERE s2.id = s.id
      AND s2.applied_skills_by_runtime IS NOT NULL
      AND jsonb_typeof(s2.applied_skills_by_runtime -> latest.runtime) = 'array'
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:sandboxes) do
      remove :applied_skills
    end
  end
end
