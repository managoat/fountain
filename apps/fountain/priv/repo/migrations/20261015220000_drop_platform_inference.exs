defmodule Fountain.Repo.Migrations.DropPlatformInference do
  use Ecto.Migration

  @moduledoc """
  Drops the deployment's inference credentials (ADR 0075).

    * `platform_inference_keys`, the keys an admin set at `/admin/inference`
      (`20260907080000`), with its `inference_source_lock` trigger.
    * The deployment's ChatGPT subscription: the one `chatgpt_subscriptions`
      row with no `user_id` (`20261013140000`). Its tokens were sealed under
      the master key. The table stays, for users' own subscriptions;
      `user_id` becomes NOT NULL and the partial unique index that allowed
      one null owner goes.

  `fountain_lock_inference_source()` loses its `platform_inference_keys`
  branch, the only one that took the `inference:platform` lock. The rest of
  the body is `20261013200000`'s, unchanged.

  The release before this one stopped reading both, so take this only after
  that release is fully rolled out: a replica of any release before it reads
  the table on every resolution.

  `down` restores the shape, not the values: the table comes back empty with
  its trigger, the function with its branch, and `user_id` nullable with its
  index. The deleted keys and subscription are gone.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    CREATE OR REPLACE FUNCTION fountain_lock_inference_source() RETURNS trigger AS $$
    DECLARE owner_id uuid;
    BEGIN
      IF TG_TABLE_NAME = 'secrets' THEN
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

    drop table(:platform_inference_keys)

    execute("DELETE FROM chatgpt_subscriptions WHERE user_id IS NULL")
    drop index(:chatgpt_subscriptions, [], name: :chatgpt_subscriptions_one_platform_row)

    alter table(:chatgpt_subscriptions) do
      modify :user_id, :binary_id, null: false, from: {:binary_id, null: true}
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:chatgpt_subscriptions) do
      modify :user_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create unique_index(:chatgpt_subscriptions, ["(user_id IS NULL)"],
             where: "user_id IS NULL",
             name: :chatgpt_subscriptions_one_platform_row
           )

    create table(:platform_inference_keys, primary_key: false) do
      add :provider, :string, primary_key: true
      add :ciphertext, :binary, null: false
      add :updated_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :revision, :uuid, null: false, default: fragment("gen_random_uuid()")

      timestamps(type: :utc_datetime)
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

    execute(
      "CREATE TRIGGER inference_source_lock BEFORE INSERT OR UPDATE OR DELETE ON platform_inference_keys FOR EACH ROW EXECUTE FUNCTION fountain_lock_inference_source()"
    )
  end
end
