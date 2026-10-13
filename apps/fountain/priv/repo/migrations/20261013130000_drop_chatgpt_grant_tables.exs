defmodule Fountain.Repo.Migrations.DropChatgptGrantTables do
  use Ecto.Migration

  # The contract step of removing ChatGPT subscriptions (ADR 0047, 0052 and
  # 0060, retired 2026-10-13). The release that removed them stopped reading
  # all of this but left it in place, because every replica of the release
  # before it reads `platform_chatgpt_account` on a codex resolution, writes
  # `broker_sessions.managed_*` on every brokered provision and casts
  # `inference_credentials.chatgpt_grant_id` with every set it loads. Take this
  # only once that release is fully rolled out.
  #
  # Dropped, with their rows:
  #
  #   * `chatgpt_link_attempts`, the device-code sign-ins;
  #   * `platform_chatgpt_account`, every grant, the deployment's and users',
  #     with the encrypted tokens. Nothing revokes them at OpenAI;
  #   * `inference_credentials.chatgpt_grant_id`, with its deferred composite
  #     key into the grants and its partial index;
  #   * the five `broker_sessions.managed_*` columns, their two check
  #     constraints and their partial index.
  #
  # And any job of the four removed workers that has not finished: one a
  # replica of the previous release scheduled during the rollout would
  # otherwise fail on a worker this release does not have.
  #
  # `fountain_lock_inference_source()` keeps its `platform_chatgpt_account`
  # branch: the trigger goes with the table, and the branch is never reached
  # again. `down/0` recreates the shape exactly as `pg_dump -s` printed it
  # before this ran, not the rows.

  @workers ~w(
    Fountain.Workers.ChatGPTGrantKeepalive
    Fountain.Workers.ChatGPTKeepaliveSweep
    Fountain.Workers.ChatGPTLinkAttempt
    Fountain.Workers.PlatformChatGPTKeepalive
  )

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    DELETE FROM oban_jobs
    WHERE worker IN (#{Enum.map_join(@workers, ", ", &"'#{&1}'")})
      AND state NOT IN ('completed', 'discarded', 'cancelled')
    """)

    execute("DROP INDEX IF EXISTS broker_sessions_managed_grant_id_index")

    execute("""
    ALTER TABLE broker_sessions
      DROP CONSTRAINT managed_grant_complete,
      DROP CONSTRAINT managed_grant_owner_is_session_owner,
      DROP COLUMN managed_grant_id,
      DROP COLUMN managed_grant_generation,
      DROP COLUMN managed_grant_owner_id,
      DROP COLUMN managed_identity,
      DROP COLUMN managed_revoked_at
    """)

    execute("DROP INDEX IF EXISTS inference_credentials_chatgpt_grant_id_index")

    execute("""
    ALTER TABLE inference_credentials
      DROP CONSTRAINT inference_credentials_chatgpt_grant_id_fkey,
      DROP COLUMN chatgpt_grant_id
    """)

    execute("DROP TABLE chatgpt_link_attempts")
    execute("DROP TABLE platform_chatgpt_account")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    CREATE TABLE public.platform_chatgpt_account (
        id uuid NOT NULL,
        user_id uuid,
        kind character varying(255) NOT NULL,
        refresh_token_ciphertext bytea,
        access_token_ciphertext bytea,
        id_claims jsonb DEFAULT '{}'::jsonb NOT NULL,
        account_id character varying(255),
        account_email character varying(255),
        plan_type character varying(255),
        access_expires_at timestamp(0) without time zone,
        last_refreshed_at timestamp(0) without time zone,
        status character varying(255) DEFAULT 'active'::character varying NOT NULL,
        revoked_reason character varying(255),
        updated_by_user_id uuid,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        generation uuid DEFAULT gen_random_uuid() NOT NULL,
        lock_version bigint DEFAULT 1 NOT NULL,
        usage_exhausted_at timestamp(0) without time zone,
        usage_exhausted_until timestamp(0) without time zone,
        usage_checked_at timestamp(0) without time zone,
        name character varying(255),
        CONSTRAINT chatgpt_grant_name_follows_owner CHECK ((((user_id IS NULL) AND (name IS NULL)) OR ((user_id IS NOT NULL) AND (name IS NOT NULL) AND (btrim((name)::text) <> ''::text)))),
        CONSTRAINT chatgpt_grant_positive_version CHECK ((lock_version > 0)),
        CONSTRAINT chatgpt_grant_tokens_follow_status CHECK (((((status)::text = 'disconnected'::text) AND (user_id IS NOT NULL) AND (access_token_ciphertext IS NULL) AND (refresh_token_ciphertext IS NULL)) OR (((status)::text <> 'disconnected'::text) AND (access_token_ciphertext IS NOT NULL)))),
        CONSTRAINT platform_chatgpt_account_pkey PRIMARY KEY (id),
        CONSTRAINT platform_chatgpt_account_updated_by_user_id_fkey FOREIGN KEY (updated_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL,
        CONSTRAINT platform_chatgpt_account_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
    )
    """)

    execute(
      "CREATE UNIQUE INDEX platform_chatgpt_account_id_user_id_index ON public.platform_chatgpt_account USING btree (id, user_id)"
    )

    execute(
      "CREATE UNIQUE INDEX platform_chatgpt_account_platform_row ON public.platform_chatgpt_account USING btree (((user_id IS NULL))) WHERE (user_id IS NULL)"
    )

    execute(
      "CREATE UNIQUE INDEX platform_chatgpt_account_user_id_account_id_index ON public.platform_chatgpt_account USING btree (user_id, account_id) WHERE (user_id IS NOT NULL)"
    )

    execute(
      "CREATE UNIQUE INDEX platform_chatgpt_account_user_id_name_index ON public.platform_chatgpt_account USING btree (user_id, name) WHERE (user_id IS NOT NULL)"
    )

    execute(
      "CREATE TRIGGER inference_source_lock BEFORE INSERT OR DELETE OR UPDATE ON public.platform_chatgpt_account FOR EACH ROW EXECUTE FUNCTION public.fountain_lock_inference_source()"
    )

    execute("""
    CREATE TABLE public.chatgpt_link_attempts (
        id uuid NOT NULL,
        user_id uuid NOT NULL,
        grant_id uuid,
        expected_generation uuid,
        name character varying(255),
        device_auth_ciphertext bytea,
        user_code_ciphertext bytea,
        verification_url character varying(255) NOT NULL,
        poll_interval integer NOT NULL,
        poll_failures integer DEFAULT 0 NOT NULL,
        state character varying(255) DEFAULT 'pending'::character varying NOT NULL,
        failure_reason character varying(255),
        result_grant_id uuid,
        conflict_grant_id uuid,
        expires_at timestamp(0) without time zone NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        CONSTRAINT chatgpt_link_attempt_outcome CHECK (((((state)::text = 'failed'::text) = (failure_reason IS NOT NULL)) AND (((state)::text = 'completed'::text) = (result_grant_id IS NOT NULL)) AND ((conflict_grant_id IS NULL) OR ((state)::text = 'failed'::text)))),
        CONSTRAINT chatgpt_link_attempt_poll_interval CHECK ((poll_interval >= 1)),
        CONSTRAINT chatgpt_link_attempt_secrets_follow_state CHECK (((((state)::text = 'pending'::text) = (device_auth_ciphertext IS NOT NULL)) AND (((state)::text = 'pending'::text) = (user_code_ciphertext IS NOT NULL)))),
        CONSTRAINT chatgpt_link_attempt_state CHECK (state IN ('pending', 'completed', 'cancelled', 'expired', 'failed')),
        CONSTRAINT chatgpt_link_attempt_target CHECK ((((name IS NULL) <> (grant_id IS NULL)) AND ((grant_id IS NULL) = (expected_generation IS NULL)))),
        CONSTRAINT chatgpt_link_attempts_pkey PRIMARY KEY (id),
        CONSTRAINT chatgpt_link_attempts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
    )
    """)

    execute(
      "CREATE UNIQUE INDEX chatgpt_link_attempts_open_reconnect ON public.chatgpt_link_attempts USING btree (grant_id) WHERE ((state)::text = 'pending'::text)"
    )

    execute(
      "CREATE INDEX chatgpt_link_attempts_user_id_inserted_at_index ON public.chatgpt_link_attempts USING btree (user_id, inserted_at)"
    )

    execute(
      "CREATE INDEX chatgpt_link_attempts_user_id_state_index ON public.chatgpt_link_attempts USING btree (user_id, state)"
    )

    execute("""
    ALTER TABLE inference_credentials
      ADD COLUMN chatgpt_grant_id uuid,
      ADD CONSTRAINT inference_credentials_chatgpt_grant_id_fkey
        FOREIGN KEY (chatgpt_grant_id, user_id)
        REFERENCES public.platform_chatgpt_account(id, user_id)
        DEFERRABLE INITIALLY DEFERRED
    """)

    execute(
      "CREATE INDEX inference_credentials_chatgpt_grant_id_index ON public.inference_credentials USING btree (chatgpt_grant_id) WHERE (chatgpt_grant_id IS NOT NULL)"
    )

    execute("""
    ALTER TABLE broker_sessions
      ADD COLUMN managed_grant_id uuid,
      ADD COLUMN managed_grant_generation uuid,
      ADD COLUMN managed_grant_owner_id uuid,
      ADD COLUMN managed_identity character varying(255),
      ADD COLUMN managed_revoked_at timestamp without time zone,
      ADD CONSTRAINT managed_grant_complete CHECK ((((managed_grant_id IS NULL) = (managed_grant_generation IS NULL)) AND ((managed_grant_id IS NULL) = (managed_identity IS NULL)) AND ((managed_grant_id IS NOT NULL) OR ((managed_grant_owner_id IS NULL) AND (managed_revoked_at IS NULL))))),
      ADD CONSTRAINT managed_grant_owner_is_session_owner CHECK (((managed_grant_owner_id IS NULL) OR (managed_grant_owner_id = user_id)))
    """)

    execute(
      "CREATE INDEX broker_sessions_managed_grant_id_index ON public.broker_sessions USING btree (managed_grant_id) WHERE (managed_grant_id IS NOT NULL)"
    )
  end
end
