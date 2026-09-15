### Upgrade notes

- **Migration `20260915220000` adds an explicit environment access policy to
  agents** (#2107). Generated `environment_access` columns on `agents` and
  `agent_versions` replace the legacy "null means any environment" reading of
  `allowed_environment_ids`. No agent changes what it can reach and no client
  changes: `null` still permits every current and future environment the tenant
  owns, `[]` permits no override, and a list permits those IDs. The columns are
  `STORED`, so the migration rewrites both tables under exclusive locks — read
  [Environment policy migration](https://managoat.com/docs/guides/operate/upgrade#environment-policy-migration)
  before upgrading a busy database.
