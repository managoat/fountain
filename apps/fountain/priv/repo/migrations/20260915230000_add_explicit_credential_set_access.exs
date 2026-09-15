defmodule Fountain.Repo.Migrations.AddExplicitCredentialSetAccess do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # The last of the three (vaults 20260913180000, environments
    # 20260915220000); the reasoning there applies unchanged. STORED columns
    # rewrite these tables under ACCESS EXCLUSIVE locks, so both statements
    # stay in this transaction: a timeout rolls the whole step back.
    # Generation covers old writers atomically throughout a rolling upgrade.
    execute """
    ALTER TABLE agents ADD COLUMN inference_credential_access text GENERATED ALWAYS AS (
      CASE WHEN allowed_inference_credential_ids IS NULL THEN 'all_tenant_credential_sets'
           ELSE 'allowlist' END
    ) STORED NOT NULL
    """

    # A missing snapshot key preserves the current value on partial restore;
    # JSON null explicitly restores unrestricted access. Do not conflate them
    # or bless malformed historical payloads (rollback revalidates config).
    execute """
    ALTER TABLE agent_versions ADD COLUMN inference_credential_access text GENERATED ALWAYS AS (
      CASE WHEN NOT (config ? 'allowed_inference_credential_ids') THEN 'unchanged'
           WHEN config->'allowed_inference_credential_ids' = 'null'::jsonb
             THEN 'all_tenant_credential_sets'
           WHEN jsonb_typeof(config->'allowed_inference_credential_ids') = 'array'
             THEN 'allowlist'
           ELSE 'invalid' END
    ) STORED NOT NULL
    """
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Only derived data is removed; the original arrays and snapshot configs
    # survive. This requires readers that do not select the derived columns.
    execute("ALTER TABLE agent_versions DROP COLUMN inference_credential_access")
    execute("ALTER TABLE agents DROP COLUMN inference_credential_access")
  end
end
