defmodule Fountain.Repo.Migrations.DropHomeColumns do
  use Ecto.Migration

  @moduledoc """
  The contract step of removing persistent homes and mixed-runtime guests
  (ADR 0073, #2676). The releases that removed them stopped reading these
  columns but left them in place, because every replica of the release
  before selects them with every sandbox and agent it loads. Take this only
  once the release with `20261014160000_one_conversation_per_sandbox` is
  fully rolled out.

  `sandboxes` loses `mode`, `runtime`, `codex_inference_source`,
  `codex_peer_homes` and `departed_conversations`, and the partial unique
  index `sandboxes_home_identity_index` (one live home per identity) that
  read `mode` and `runtime`. `conversations` loses the
  `record_departed_conversation` trigger and its function
  `fountain_record_departed_conversation()`, which wrote
  `departed_conversations` for the removed guest rule. `agents` loses
  `sandbox_mode`, which the API still accepts as `"ephemeral"` on a virtual
  field.

  `down/0` restores the shape with the columns' defaults, not the values:
  every machine comes back as `ephemeral` with no recorded runtime, and the
  trigger is not recreated.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("DROP TRIGGER IF EXISTS record_departed_conversation ON conversations")
    execute("DROP FUNCTION IF EXISTS fountain_record_departed_conversation()")

    execute("DROP INDEX IF EXISTS sandboxes_home_identity_index")

    execute("""
    ALTER TABLE sandboxes
      DROP COLUMN mode,
      DROP COLUMN runtime,
      DROP COLUMN codex_inference_source,
      DROP COLUMN codex_peer_homes,
      DROP COLUMN departed_conversations
    """)

    execute("ALTER TABLE agents DROP COLUMN sandbox_mode")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE agents ADD COLUMN sandbox_mode varchar(255) NOT NULL DEFAULT 'ephemeral'
    """)

    execute("""
    ALTER TABLE sandboxes
      ADD COLUMN mode varchar(255) NOT NULL DEFAULT 'ephemeral',
      ADD COLUMN runtime varchar(255),
      ADD COLUMN codex_inference_source jsonb,
      ADD COLUMN codex_peer_homes boolean NOT NULL DEFAULT false,
      ADD COLUMN departed_conversations jsonb NOT NULL DEFAULT '[]'::jsonb
    """)

    execute("""
    CREATE UNIQUE INDEX sandboxes_home_identity_index
      ON sandboxes (user_id, agent_id, environment_id, vault_id, runtime) NULLS NOT DISTINCT
      WHERE mode = 'persistent' AND status NOT IN ('terminated', 'failed')
    """)
  end
end
