defmodule Fountain.Repo.Migrations.RecordAppliedSkillsPerRuntime do
  use Ecto.Migration

  # #2514 (ADR 0023, 2026-09-26 amendment). `applied_skills` held one skill
  # selection per machine: the record a skills reconciliation reads to know
  # which entries under the runtime's skills root are Fountain's. Once a
  # conversation of another runtime may share the machine, each runtime has
  # its own skills root (`.claude/skills`, `.codex/skills`), so the record is
  # kept per runtime: `{"claude": [...], "codex": [...]}`.
  #
  # **A new column, not a new type for the old one.** A replica still running
  # the previous release during a rolling upgrade loads every sandbox row with
  # `applied_skills` typed as a list; turning that column into an object would
  # fail each of those loads. The old column is left in place, no longer read
  # or written, and a later release drops it. The cost of the overlap is small:
  # the record is consulted only when a disk has no skills manifest yet, and
  # the first reconciliation on any release writes one.
  #
  # **Keyed by the runtime that shaped the disk.** `sandboxes.runtime`, or,
  # where that is NULL on a legacy row, the newest retained conversation's
  # runtime, the same evidence `20260918050000_add_sandbox_runtime_identity`
  # used. A row with neither gets no per-runtime record: an entry under a
  # guessed runtime would be read as ownership by that runtime's
  # reconciliation, while no record falls back to the conversation's own
  # Agent version, which is what every disk older than the record already
  # does.
  def up do
    alter table(:sandboxes) do
      add :applied_skills_by_runtime, :map
    end

    flush()

    execute("""
    UPDATE sandboxes AS s
    SET applied_skills_by_runtime =
      jsonb_build_object(owner.runtime, to_jsonb(s.applied_skills))
    FROM (
      SELECT s2.id, COALESCE(s2.runtime, latest.runtime) AS runtime
      FROM sandboxes AS s2
      LEFT JOIN LATERAL (
        SELECT c.runtime
        FROM conversations AS c
        WHERE c.sandbox_id = s2.id AND c.user_id = s2.user_id
        ORDER BY c.inserted_at DESC, c.id DESC
        LIMIT 1
      ) AS latest ON true
      WHERE s2.applied_skills IS NOT NULL
    ) AS owner
    WHERE owner.id = s.id AND owner.runtime IS NOT NULL
    """)
  end

  # Writes made since `up` go back into the list column for the runtime that
  # shaped the disk, so a rollback loses no record on a single-runtime
  # machine. Another runtime's entry has nowhere to go and is dropped; its
  # reconciliation falls back to its conversation's Agent version, as on a
  # disk that never had a record. A row with no entry for its own runtime
  # keeps the list column as `up` left it.
  def down do
    execute("""
    UPDATE sandboxes AS s
    SET applied_skills = ARRAY(
      SELECT jsonb_array_elements(s.applied_skills_by_runtime -> owner.runtime)
    )
    FROM (
      SELECT s2.id, COALESCE(s2.runtime, latest.runtime) AS runtime
      FROM sandboxes AS s2
      LEFT JOIN LATERAL (
        SELECT c.runtime
        FROM conversations AS c
        WHERE c.sandbox_id = s2.id AND c.user_id = s2.user_id
        ORDER BY c.inserted_at DESC, c.id DESC
        LIMIT 1
      ) AS latest ON true
      WHERE s2.applied_skills_by_runtime IS NOT NULL
    ) AS owner
    WHERE owner.id = s.id
      AND owner.runtime IS NOT NULL
      AND jsonb_typeof(s.applied_skills_by_runtime -> owner.runtime) = 'array'
    """)

    alter table(:sandboxes) do
      remove :applied_skills_by_runtime
    end
  end
end
