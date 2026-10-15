### Upgrade notes

- **The console no longer has agent, environment or vault pages** (#2732,
  [ADR 0076](https://github.com/managoat/fountain/blob/main/decisions/0076-console-without-configuration-pages.md)).
  `/agents*`, `/environments*`, `/vaults*` and the session-authenticated
  `/agents/:id/avatar` now return 404. Create and edit them in the
  Conversations app (`#/agents`, `#/environments`, `#/vaults`), with
  `fountain apply` and `fountain vault`, or over `/api`, which is unchanged.
  [The console, the apps, and the API](https://managoat.com/docs/concepts/surfaces#retired-browser-urls)
  lists the destination for each retired path.

### Removed

- The dashboard's Agents, Environments and Vaults counts (#2732).
- Rolling an agent back to an earlier version from the console (#2732).
  Versions stay readable with `GET /api/agents/:id/versions`; to go back,
  write a version's config to the agent again.

### Changed

- **`/help` and `/help/:topic` redirect to the manual** (#2732) instead of
  answering 404: to `/docs`, or to the page that took the retired topic. The
  manifest format and secret managers now have their own page,
  [Manage resources as YAML](https://managoat.com/docs/guides/manifests).
- The vault secret expiry email links no page (#2732). It names each vault
  and key with the `fountain vault set-secret` command that replaces the
  value, and the `PATCH` call that records the new expiry.

### Added

- `MASTER_SECRETS_KEY` rotation, account erasure and audit-log trimming in
  [Back up and restore](https://managoat.com/docs/guides/operate/back-up-and-restore)
  (#2732), moved from the retired help.
