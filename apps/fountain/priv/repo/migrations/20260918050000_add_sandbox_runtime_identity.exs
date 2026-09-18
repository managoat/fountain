defmodule Fountain.Repo.Migrations.AddSandboxRuntimeIdentity do
  use Ecto.Migration

  def up do
    alter table(:sandboxes) do
      add :runtime, :string
    end

    flush()

    # Match the old attach door's evidence: the newest retained conversation.
    # The agent may already have changed runtime, so it is not a safe backfill.
    # A disk without retained evidence stays unknown and is never auto-selected.
    execute("""
    UPDATE sandboxes AS s SET runtime = latest.runtime
    FROM (
      SELECT DISTINCT ON (sandbox_id) sandbox_id, user_id, runtime
      FROM conversations
      WHERE sandbox_id IS NOT NULL
      ORDER BY sandbox_id, inserted_at DESC, id DESC
    ) AS latest
    WHERE latest.sandbox_id = s.id AND latest.user_id = s.user_id
    """)

    drop index(:sandboxes, [:user_id, :agent_id, :environment_id, :vault_id],
           name: :sandboxes_home_identity_index
         )

    create unique_index(:sandboxes, [:user_id, :agent_id, :environment_id, :vault_id, :runtime],
             name: :sandboxes_home_identity_index,
             where: "mode = 'persistent' AND status NOT IN ('terminated', 'failed')",
             nulls_distinct: false
           )
  end

  def down do
    # Refuse rollback if two runtime-specific homes now share the old key.
    # Build the old constraint first: never delete a disk to make it fit.
    create unique_index(:sandboxes, [:user_id, :agent_id, :environment_id, :vault_id],
             name: :sandboxes_home_identity_legacy_index,
             where: "mode = 'persistent' AND status NOT IN ('terminated', 'failed')",
             nulls_distinct: false
           )

    drop index(:sandboxes, [:user_id, :agent_id, :environment_id, :vault_id, :runtime],
           name: :sandboxes_home_identity_index
         )

    rename index(:sandboxes, [:user_id, :agent_id, :environment_id, :vault_id],
             name: :sandboxes_home_identity_legacy_index
           ),
           to: :sandboxes_home_identity_index

    alter table(:sandboxes) do
      remove :runtime
    end
  end
end
