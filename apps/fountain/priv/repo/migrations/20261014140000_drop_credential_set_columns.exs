defmodule Fountain.Repo.Migrations.DropCredentialSetColumns do
  use Ecto.Migration

  @moduledoc """
  The contract step of collapsing inference credential sets to one record
  per user (ADR 0053's 2026-10-14 addendum, #2658). The release that
  collapsed them unmapped all of this but left it in place, because every
  replica of the release before it selects these columns with every agent,
  conversation and credential row it loads. Take this only once that
  release is fully rolled out.

  `inference_credentials` loses `name`, `is_default` and both set indexes,
  and gets its unique key on `user_id` back. A replica of the previous
  release could still have written a second row during that rollout, so the
  newer rows of any user holding more than one are deleted first: the
  oldest is the one that release read (`InferenceCredentials.get_for_user/1`).

  `agents` loses `inference_credential_id` (with its key and index),
  `allowed_inference_credential_ids` and the generated
  `inference_credential_access`; `agent_versions` loses its generated
  `inference_credential_access`. The version snapshots keep whatever keys
  they recorded: nothing casts them back.

  `conversations` loses `inference_credential_id`, with its key and index.
  `fountain_record_departed_conversation()` reads that column, so it is
  redefined first without it; the descriptors already written keep the key,
  and nothing reads it.

  `down/0` restores the shape, not the values.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    DELETE FROM inference_credentials AS c
     USING inference_credentials AS d
     WHERE c.user_id = d.user_id
       AND (d.inserted_at, d.id) < (c.inserted_at, c.id)
    """)

    execute("DROP INDEX inference_credentials_one_default_index")
    execute("DROP INDEX inference_credentials_user_id_name_index")
    execute("ALTER TABLE inference_credentials DROP COLUMN name, DROP COLUMN is_default")
    create unique_index(:inference_credentials, [:user_id])

    execute(departed_function(false))

    execute("DROP INDEX conversations_inference_credential_id_index")
    execute("ALTER TABLE conversations DROP COLUMN inference_credential_id")

    execute("ALTER TABLE agent_versions DROP COLUMN inference_credential_access")

    execute("DROP INDEX agents_inference_credential_id_index")

    execute("""
    ALTER TABLE agents
      DROP COLUMN inference_credential_access,
      DROP COLUMN allowed_inference_credential_ids,
      DROP COLUMN inference_credential_id
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    ALTER TABLE agents
      ADD COLUMN inference_credential_id uuid
        REFERENCES inference_credentials(id) ON DELETE SET NULL,
      ADD COLUMN allowed_inference_credential_ids uuid[]
    """)

    execute(
      "CREATE INDEX agents_inference_credential_id_index ON agents (inference_credential_id)"
    )

    execute("""
    ALTER TABLE agents ADD COLUMN inference_credential_access text GENERATED ALWAYS AS (
      CASE WHEN allowed_inference_credential_ids IS NULL THEN 'all_tenant_credential_sets'
           ELSE 'allowlist' END
    ) STORED NOT NULL
    """)

    execute("""
    ALTER TABLE agent_versions ADD COLUMN inference_credential_access text GENERATED ALWAYS AS (
      CASE WHEN NOT (config ? 'allowed_inference_credential_ids') THEN 'unchanged'
           WHEN config->'allowed_inference_credential_ids' = 'null'::jsonb
             THEN 'all_tenant_credential_sets'
           WHEN jsonb_typeof(config->'allowed_inference_credential_ids') = 'array'
             THEN 'allowlist'
           ELSE 'invalid' END
    ) STORED NOT NULL
    """)

    execute("""
    ALTER TABLE conversations
      ADD COLUMN inference_credential_id uuid
        REFERENCES inference_credentials(id) ON DELETE SET NULL
    """)

    execute(
      "CREATE INDEX conversations_inference_credential_id_index ON conversations (inference_credential_id)"
    )

    execute(departed_function(true))

    drop index(:inference_credentials, [:user_id])

    execute("""
    ALTER TABLE inference_credentials
      ADD COLUMN name character varying(255) NOT NULL DEFAULT 'Default',
      ADD COLUMN is_default boolean NOT NULL DEFAULT TRUE
    """)

    execute(
      "CREATE UNIQUE INDEX inference_credentials_user_id_name_index ON inference_credentials (user_id, name)"
    )

    execute(
      "CREATE UNIQUE INDEX inference_credentials_one_default_index ON inference_credentials (user_id) WHERE is_default"
    )
  end

  # `20260927090000`'s body, with or without the descriptor's
  # `inference_credential_id`.
  defp departed_function(with_credential?) do
    credential =
      if with_credential?,
        do: "\n               'inference_credential_id', OLD.inference_credential_id,",
        else: ""

    """
    CREATE OR REPLACE FUNCTION fountain_record_departed_conversation() RETURNS trigger AS $$
    DECLARE descriptor jsonb;
    BEGIN
      IF OLD.sandbox_id IS NULL THEN RETURN NULL; END IF;
      IF TG_OP = 'UPDATE' AND OLD.sandbox_id IS NOT DISTINCT FROM NEW.sandbox_id THEN
        RETURN NULL;
      END IF;

      SELECT jsonb_build_object(
               'conversation_id', OLD.id,
               'agent_id', OLD.agent_id,
               'runtime', OLD.runtime,
               'model', OLD.model,
               'inference_source', OLD.inference_source,#{credential}
               'environment_id', COALESCE(OLD.environment_id, s.environment_id),
               'vault_id', OLD.vault_id)
        INTO descriptor
        FROM sandboxes AS s
       WHERE s.id = OLD.sandbox_id;

      IF descriptor IS NULL THEN RETURN NULL; END IF;

      UPDATE sandboxes AS s
         SET departed_conversations = s.departed_conversations || jsonb_build_array(descriptor)
       WHERE s.id = OLD.sandbox_id
         AND s.status NOT IN ('terminated', 'failed')
         AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(s.departed_conversations) AS e
            WHERE (e - 'conversation_id') = (descriptor - 'conversation_id'));

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """
  end
end
