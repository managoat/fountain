defmodule Fountain.Repo.Migrations.DropDeferredWebhookAndConnectionTables do
  @moduledoc """
  The contract step for `20261012170000_drop_account_exports` (webhooks and the
  account data export, simplify 4/5) and the Connections removal (simplify 5/5).

  Those releases stopped reading `webhook_endpoints`, `webhook_deliveries`,
  `connections` and `connection_providers` but left them in place: a rolling
  deploy runs a migration while replicas of the previous release still serve,
  and those read `webhook_endpoints` on every stage transition (inside the turn
  deadline transaction) and `connections` on every brokered provision and turn
  kick. Take this only after the release that removed both is fully rolled out;
  the release before this one reads none of them.

  Nothing else references these tables. `down` restores their exact shape
  (taken from the schema the earlier migrations produce), not their rows; the
  stored OAuth tokens and webhook secrets are gone for good.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:webhook_deliveries)
    drop_if_exists table(:webhook_endpoints)
    drop_if_exists table(:connections)
    drop_if_exists table(:connection_providers)
  end

  def down do
    execute """
    CREATE TABLE connection_providers (
        id uuid NOT NULL,
        user_id uuid NOT NULL,
        slug character varying(255) NOT NULL,
        name character varying(255) NOT NULL,
        kind character varying(255) NOT NULL,
        authorize_url character varying(255),
        token_url character varying(255),
        revoke_url character varying(255),
        userinfo_url character varying(255),
        account_label_path character varying(255),
        scopes character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        client_id character varying(255),
        client_secret_ciphertext bytea,
        token_endpoint_auth character varying(255) DEFAULT 'client_secret_post'::character varying NOT NULL,
        pkce boolean DEFAULT true NOT NULL,
        env_key character varying(255) NOT NULL,
        token_hosts character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        mcp_url character varying(255),
        issuer character varying(255),
        mcp_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
        client_source character varying(255),
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """

    execute """
    CREATE TABLE connections (
        id uuid NOT NULL,
        user_id uuid NOT NULL,
        provider character varying(255) NOT NULL,
        account_email character varying(255) NOT NULL,
        scopes character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        env_key character varying(255) NOT NULL,
        refresh_token_ciphertext bytea,
        access_token_ciphertext bytea,
        expires_at timestamp(0) without time zone,
        status character varying(255) DEFAULT 'active'::character varying NOT NULL,
        revoked_at timestamp(0) without time zone,
        last_refreshed_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        provider_id uuid
    )
    """

    execute """
    CREATE TABLE webhook_deliveries (
        id uuid NOT NULL,
        webhook_endpoint_id uuid NOT NULL,
        event_id character varying(255) NOT NULL,
        event_type character varying(255) NOT NULL,
        attempt integer DEFAULT 1 NOT NULL,
        status_code integer,
        duration_ms integer,
        error character varying(255),
        response_body text,
        payload jsonb DEFAULT '{}'::jsonb NOT NULL,
        inserted_at timestamp without time zone NOT NULL,
        updated_at timestamp without time zone NOT NULL
    )
    """

    execute """
    CREATE TABLE webhook_endpoints (
        id uuid NOT NULL,
        user_id uuid NOT NULL,
        url character varying(2000) NOT NULL,
        description character varying(255),
        secret_ciphertext bytea NOT NULL,
        event_types character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        status character varying(255) DEFAULT 'active'::character varying NOT NULL,
        consecutive_failures integer DEFAULT 0 NOT NULL,
        disabled_at timestamp(0) without time zone,
        disabled_reason character varying(255),
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """

    execute """
    ALTER TABLE ONLY connection_providers
        ADD CONSTRAINT connection_providers_pkey PRIMARY KEY (id)
    """

    execute """
    ALTER TABLE ONLY connections
        ADD CONSTRAINT connections_pkey PRIMARY KEY (id)
    """

    execute """
    ALTER TABLE ONLY webhook_deliveries
        ADD CONSTRAINT webhook_deliveries_pkey PRIMARY KEY (id)
    """

    execute """
    ALTER TABLE ONLY webhook_endpoints
        ADD CONSTRAINT webhook_endpoints_pkey PRIMARY KEY (id)
    """

    execute """
    CREATE UNIQUE INDEX connection_providers_user_id_env_key_index ON connection_providers USING btree (user_id, env_key)
    """

    execute """
    CREATE INDEX connection_providers_user_id_issuer_index ON connection_providers USING btree (user_id, issuer)
    """

    execute """
    CREATE UNIQUE INDEX connection_providers_user_id_slug_index ON connection_providers USING btree (user_id, slug)
    """

    execute """
    CREATE UNIQUE INDEX connections_platform_account_index ON connections USING btree (user_id, provider, account_email) WHERE (provider_id IS NULL)
    """

    execute """
    CREATE INDEX connections_provider_id_index ON connections USING btree (provider_id)
    """

    execute """
    CREATE UNIQUE INDEX connections_tenant_provider_account_index ON connections USING btree (user_id, provider_id, account_email) WHERE (provider_id IS NOT NULL)
    """

    execute """
    CREATE UNIQUE INDEX connections_user_id_env_key_index ON connections USING btree (user_id, env_key)
    """

    execute """
    CREATE INDEX connections_user_id_status_index ON connections USING btree (user_id, status)
    """

    execute """
    CREATE INDEX webhook_deliveries_inserted_at_index ON webhook_deliveries USING btree (inserted_at)
    """

    execute """
    CREATE INDEX webhook_deliveries_webhook_endpoint_id_inserted_at_index ON webhook_deliveries USING btree (webhook_endpoint_id, inserted_at)
    """

    execute """
    CREATE INDEX webhook_endpoints_user_id_index ON webhook_endpoints USING btree (user_id)
    """

    execute """
    CREATE INDEX webhook_endpoints_user_id_status_index ON webhook_endpoints USING btree (user_id, status)
    """

    execute """
    ALTER TABLE ONLY connection_providers
        ADD CONSTRAINT connection_providers_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE ONLY connections
        ADD CONSTRAINT connections_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES connection_providers(id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE ONLY connections
        ADD CONSTRAINT connections_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE ONLY webhook_deliveries
        ADD CONSTRAINT webhook_deliveries_webhook_endpoint_id_fkey FOREIGN KEY (webhook_endpoint_id) REFERENCES webhook_endpoints(id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE ONLY webhook_endpoints
        ADD CONSTRAINT webhook_endpoints_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """
  end
end
