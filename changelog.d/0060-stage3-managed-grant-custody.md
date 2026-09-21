### Upgrade notes

- **Two additive migrations, no operator action** (#2457).
  `20260921021249` adds five nullable columns, a partial index and two check
  constraints to `broker_sessions`: which managed ChatGPT grant a broker
  session may use, at which generation, for which owner and ChatGPT account,
  and when that was revoked. `20260921023458` adds
  `sandboxes.codex_peer_homes`, `false` on every existing row and set on a
  new codex sandbox the first time a conversation is bound to it. Both are
  safe under a rolling upgrade, and neither changes how an existing session
  or sandbox behaves. They belong to the broker path a user's own ChatGPT
  subscription will run on (ADR 0060), and that the deployment's own ChatGPT
  account now runs on. That move is not additive: it deletes broker
  sessions, fails codex turns on the account during a rolling upgrade, and
  has notes of its own in this section. Linking a subscription is behind a
  flag that is off until someone turns it on. Rolling `20260921021249` back deletes
  any broker session that carries a managed grant; its conversation mints a
  new one on its next turn.

### Fixed

- **A secret whose value mentions `CODEX_CHATGPT_ACCESS_TOKEN` can be saved**
  (#2457). Environment and vault secrets refused any value that contained
  the reserved name, in any case, so a setup script or a JSON blob that
  mentions it failed with "is reserved for managed ChatGPT credentials". A
  value is now refused only when it is the reserved name by itself, contains
  one of the managed credential's placeholders, or contains a
  `{{ CODEX_CHATGPT_ACCESS_TOKEN }}` reference. The name is still refused
  as a secret's key and anywhere in a secret binding.
