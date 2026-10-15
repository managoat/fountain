defmodule Fountain.Repo.Migrations.DropSandboxAppliedSkillsByRuntime do
  @moduledoc """
  Drops `sandboxes.applied_skills_by_runtime` (`20260926150000`, #2514).

  `20261016150000_flatten_sandbox_applied_skills` replaced it with the one
  list `applied_skills` and the release that shipped it stopped reading and
  writing the map. Take this only after that release is rolled out: a release
  before it maps the column, and Ecto selects every mapped field.

  `down/0` restores the column from `applied_skills`, keyed by the runtime of
  each sandbox's newest conversation, so the release before can read it.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:sandboxes) do
      remove :applied_skills_by_runtime
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:sandboxes) do
      add :applied_skills_by_runtime, :map
    end

    flush()

    execute("""
    UPDATE sandboxes AS s
    SET applied_skills_by_runtime = jsonb_build_object(latest.runtime, to_jsonb(s.applied_skills))
    FROM sandboxes AS s2
    CROSS JOIN LATERAL (
      SELECT c.runtime
      FROM conversations AS c
      WHERE c.sandbox_id = s2.id AND c.user_id = s2.user_id
      ORDER BY c.inserted_at DESC, c.id DESC
      LIMIT 1
    ) AS latest
    WHERE s2.id = s.id AND s2.applied_skills IS NOT NULL
    """)
  end
end
