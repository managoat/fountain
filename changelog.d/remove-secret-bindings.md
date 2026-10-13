### Upgrade notes

- **Credential bindings are removed** (#1090). `/api/secret-bindings` and its
  `presets` route answer `404`, and the Credential bindings page and its nav
  link are gone. With the egress broker on, the broker now carries only
  `GITHUB_TOKEN`/`GH_TOKEN` (to GitHub) and the runtime's inference
  credential; any other secret, including one you had bound, reaches the
  sandbox in the clear. The `secret_bindings` table stays for one release,
  unread, and a later migration drops it.

### Removed

- Credential bindings (ADR 0019 gate 1b): the `Fountain.SecretBindings`
  context, its 35-entry preset catalog, `/api/secret-bindings`, the
  `/account/bindings` page, and the bearer, basic, API-key and custom-header
  broker rule shapes only a binding could ask for (#1090).
