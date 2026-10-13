### Upgrade notes

- **Claimable principals are removed** (#2607). Migration `20261012120000`
  drops `claimable_users` and `principal_owners`, deletes any remaining
  principal account with its rows, and makes `users.email` required again. It
  cannot stop a principal's sandboxes: release every open principal before
  upgrading. See
  [Claimable principals removed](https://managoat.com/docs/guides/operate/upgrade#claimable-principals-removed).

### Removed

- `/api/claimable-users` and its inference-credential routes, the `principal`
  API-key scope, the "Start before sign-in" guide, and the principal key
  picker on the API keys page (#2607, ADR 0044).
