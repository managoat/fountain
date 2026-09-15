### Upgrade notes

- **Migration `20260915230000` adds an explicit credential set access policy to
  agents** (#2107). Generated `inference_credential_access` columns on `agents`
  and `agent_versions` replace the legacy "null means any set" reading of
  `allowed_inference_credential_ids`, completing the set of three allowlists.
  No agent changes what it can reach and no client changes: `null` still
  permits every current and future credential set the tenant owns, `[]` permits
  no override, and a list permits those IDs. The columns are `STORED`, so the
  migration rewrites both tables under exclusive locks — read
  [Credential set policy migration](https://managoat.com/docs/guides/operate/upgrade#credential-set-policy-migration)
  before upgrading a busy database.
