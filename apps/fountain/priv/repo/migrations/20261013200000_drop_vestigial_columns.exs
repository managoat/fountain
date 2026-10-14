defmodule Fountain.Repo.Migrations.DropVestigialColumns do
  use Ecto.Migration

  @moduledoc """
  Drops six columns nothing reads any more, and a dead branch of a trigger
  function.

    * `users.onboarding_completed_at` (`20260510100000`). Unmapped since the
      onboarding state moved off `users` (`20260902120000`).
    * `sandboxes.applied_skills` (`20260911030000`). Replaced by
      `applied_skills_by_runtime` in `20260926150000`, which said a later
      release drops it; unmapped since.
    * `users.conversations_roots_only`, `users.conversation_visible_streams`
      and `users.conversation_view_mode` (`20260513000000`,
      `20260513000001`), the old conversation-list preferences.
    * `sandboxes.provider_instance_id` (`20260911010000`) with its partial
      unique index on `(provider, provider_instance_id)`. Nothing has written
      it since the module that did was removed (stage 8b).

  The last four were still mapped by `Fountain.Accounts.User` and
  `Fountain.Conversations.Sandbox` until the release that unmapped them.
  Ecto selects every mapped field, so a replica of any release before that
  one fails every user and sandbox load once this runs. Take this only after
  the release that unmapped them is fully rolled out.

  `fountain_lock_inference_source()` loses its `platform_chatgpt_account`
  branch. The only trigger that reached it was on that table, which
  `20261013160000` dropped, so the branch cannot run. The rest of the body is
  `20260921000305`'s, unchanged.

  `down` restores the shape, not the values: the columns come back with
  their original types and defaults, the index with its original name, and
  the function with the branch, so rolling back past `20261013160000` still
  recreates its table's trigger against a body that handles it.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    drop_if_exists index(:sandboxes, [:provider, :provider_instance_id])

    alter table(:sandboxes) do
      remove :provider_instance_id
      remove :applied_skills
    end

    alter table(:users) do
      remove :onboarding_completed_at
      remove :conversations_roots_only
      remove :conversation_visible_streams
      remove :conversation_view_mode
    end

    execute("""
    CREATE OR REPLACE FUNCTION fountain_lock_inference_source() RETURNS trigger AS $$
    DECLARE owner_id uuid;
    BEGIN
      IF TG_TABLE_NAME = 'platform_inference_keys' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('inference:platform', 0));
        IF TG_OP = 'UPDATE' THEN
          IF NEW.ciphertext IS DISTINCT FROM OLD.ciphertext THEN NEW.revision := gen_random_uuid(); END IF;
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
      ELSIF TG_TABLE_NAME = 'secrets' THEN
        SELECT user_id INTO owner_id FROM environments WHERE id = COALESCE(NEW.environment_id, OLD.environment_id);
      ELSIF TG_TABLE_NAME = 'vault_secrets' THEN
        SELECT user_id INTO owner_id FROM vaults WHERE id = COALESCE(NEW.vault_id, OLD.vault_id);
      ELSE
        owner_id := COALESCE(NEW.user_id, OLD.user_id);
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('inference:' || owner_id::text, 0));
      IF TG_TABLE_NAME = 'inference_credentials' AND TG_OP = 'UPDATE' THEN
        IF NEW.anthropic_api_key_ciphertext IS DISTINCT FROM OLD.anthropic_api_key_ciphertext OR
           NEW.claude_code_oauth_token_ciphertext IS DISTINCT FROM OLD.claude_code_oauth_token_ciphertext OR
           NEW.openai_api_key_ciphertext IS DISTINCT FROM OLD.openai_api_key_ciphertext OR
           NEW.gemini_api_key_ciphertext IS DISTINCT FROM OLD.gemini_api_key_ciphertext THEN
          NEW.revision := gen_random_uuid();
        END IF;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        IF TG_TABLE_NAME = 'environments' THEN
          IF NEW.env_vars IS DISTINCT FROM OLD.env_vars THEN NEW.inference_revision := gen_random_uuid(); END IF;
        ELSIF TG_TABLE_NAME IN ('secrets', 'vault_secrets') THEN
          IF NEW.value_ciphertext IS DISTINCT FROM OLD.value_ciphertext OR NEW.key IS DISTINCT FROM OLD.key THEN NEW.inference_revision := gen_random_uuid(); END IF;
        END IF;
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END;
    $$ LANGUAGE plpgsql
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    CREATE OR REPLACE FUNCTION fountain_lock_inference_source() RETURNS trigger AS $$
    DECLARE owner_id uuid;
    BEGIN
      IF TG_TABLE_NAME = 'platform_chatgpt_account' THEN
        IF TG_OP = 'UPDATE' THEN
          IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
            RAISE EXCEPTION 'a ChatGPT grant never changes its owner';
          END IF;
        END IF;
        owner_id := COALESCE(NEW.user_id, OLD.user_id);
        IF owner_id IS NULL THEN
          PERFORM pg_advisory_xact_lock(hashtextextended('inference:platform', 0));
        ELSE
          PERFORM pg_advisory_xact_lock(hashtextextended('inference:' || owner_id::text, 0));
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
      ELSIF TG_TABLE_NAME = 'platform_inference_keys' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('inference:platform', 0));
        IF TG_OP = 'UPDATE' THEN
          IF NEW.ciphertext IS DISTINCT FROM OLD.ciphertext THEN NEW.revision := gen_random_uuid(); END IF;
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
      ELSIF TG_TABLE_NAME = 'secrets' THEN
        SELECT user_id INTO owner_id FROM environments WHERE id = COALESCE(NEW.environment_id, OLD.environment_id);
      ELSIF TG_TABLE_NAME = 'vault_secrets' THEN
        SELECT user_id INTO owner_id FROM vaults WHERE id = COALESCE(NEW.vault_id, OLD.vault_id);
      ELSE
        owner_id := COALESCE(NEW.user_id, OLD.user_id);
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('inference:' || owner_id::text, 0));
      IF TG_TABLE_NAME = 'inference_credentials' AND TG_OP = 'UPDATE' THEN
        IF NEW.anthropic_api_key_ciphertext IS DISTINCT FROM OLD.anthropic_api_key_ciphertext OR
           NEW.claude_code_oauth_token_ciphertext IS DISTINCT FROM OLD.claude_code_oauth_token_ciphertext OR
           NEW.openai_api_key_ciphertext IS DISTINCT FROM OLD.openai_api_key_ciphertext OR
           NEW.gemini_api_key_ciphertext IS DISTINCT FROM OLD.gemini_api_key_ciphertext THEN
          NEW.revision := gen_random_uuid();
        END IF;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        IF TG_TABLE_NAME = 'environments' THEN
          IF NEW.env_vars IS DISTINCT FROM OLD.env_vars THEN NEW.inference_revision := gen_random_uuid(); END IF;
        ELSIF TG_TABLE_NAME IN ('secrets', 'vault_secrets') THEN
          IF NEW.value_ciphertext IS DISTINCT FROM OLD.value_ciphertext OR NEW.key IS DISTINCT FROM OLD.key THEN NEW.inference_revision := gen_random_uuid(); END IF;
        END IF;
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END;
    $$ LANGUAGE plpgsql
    """)

    alter table(:users) do
      add :onboarding_completed_at, :utc_datetime
      add :conversations_roots_only, :boolean, null: false, default: false

      add :conversation_visible_streams, {:array, :string},
        null: false,
        default: ["stdout", "stderr", "stage"]

      add :conversation_view_mode, :string, null: false, default: "pretty"
    end

    alter table(:sandboxes) do
      add :applied_skills, {:array, :map}
      add :provider_instance_id, :text
    end

    create unique_index(:sandboxes, [:provider, :provider_instance_id],
             where: "provider_instance_id IS NOT NULL"
           )
  end
end
