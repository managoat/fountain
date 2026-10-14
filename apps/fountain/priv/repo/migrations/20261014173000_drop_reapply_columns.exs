defmodule Fountain.Repo.Migrations.DropReapplyColumns do
  use Ecto.Migration

  @moduledoc """
  The contract step of removing reapply (#2676). The release that removed it
  unmapped both columns but left them in place, because every replica of the
  release before it selects them with every conversation and sandbox row it
  loads. Take this only once that release is fully rolled out.

  `conversations` loses `configuration_revision`, the counter turn admission
  compared with the revision a live server had loaded
  (`20260911030000`). `sandboxes` loses `build_fingerprint`, the digest of
  the environment's build inputs that a reapply compared against. Nothing
  reads or writes either since the removal. `applied_skills_by_runtime`
  stays: a wake's skills reconciliation still uses it.

  `down/0` restores the shape, not the values: every conversation is back at
  revision 0 and every sandbox has no fingerprint.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("ALTER TABLE conversations DROP COLUMN configuration_revision")
    execute("ALTER TABLE sandboxes DROP COLUMN build_fingerprint")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("ALTER TABLE sandboxes ADD COLUMN build_fingerprint character varying(255)")

    execute(
      "ALTER TABLE conversations ADD COLUMN configuration_revision bigint NOT NULL DEFAULT 0"
    )
  end
end
