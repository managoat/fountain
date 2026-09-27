### Added

- **Copy a vault server-side** (#PR). `POST /api/vaults/:id/copy` with
  `{"name": ...}` creates a new vault holding every secret of one you own,
  decrypted and re-encrypted on the server, so values never cross the API.
  The copy is all or nothing, returns the vault create shape, and is audited
  as `vault.created` with `copied_from` plus one `vault.secret.write` per key.
  See [Copy a vault](https://managoat.com/docs/concepts/vault#copy-a-vault).
