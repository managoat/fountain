defmodule Fountain.Repo.Migrations.KeyChatgptGrantSourceLockByOwner do
  use Ecto.Migration

  # ADR 0060 decision 5. `fountain_lock_inference_source()`
  # (`20260913120000`) took `'inference:platform'` exclusive for every row of
  # `platform_chatgpt_account`, whatever its owner, while every credential
  # resolution takes that key shared. With one platform row that is a
  # non-event; with user grants it would park every user's turn admission
  # behind any user's token refresh. A row with an owner now takes its
  # owner's key, the one `inference_credentials`, `environments` and `vaults`
  # already take; the NULL-owner row keeps the platform key.
  #
  # The function also refuses an UPDATE that changes `user_id` (ADR 0052
  # decision 1: a grant never moves between users or scopes). The column's
  # foreign key cascades on delete, so no legitimate UPDATE changes it.
  #
  # Everything else in the body is `20260913120000`'s, unchanged. The
  # `platform_chatgpt_account` branch stays in statements of its own:
  # plpgsql plans a statement when it first runs, so `NEW.user_id` must never
  # be reached for a table without that column. The triggers are not touched.
  # Safe in either order on a rolling deploy: a node that predates this only
  # ever writes the NULL-owner row, which keeps its key.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute """
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
    """
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute """
    CREATE OR REPLACE FUNCTION fountain_lock_inference_source() RETURNS trigger AS $$
    DECLARE owner_id uuid;
    BEGIN
      IF TG_TABLE_NAME IN ('platform_chatgpt_account', 'platform_inference_keys') THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('inference:platform', 0));
        IF TG_TABLE_NAME = 'platform_inference_keys' AND TG_OP = 'UPDATE' THEN
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
    """
  end
end
