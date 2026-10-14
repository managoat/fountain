### Changed

- The in-app Secrets managers help page now carries the 1Password, Bitwarden
  Secrets Manager and Infisical guides as sections. Their links pointed at
  pages the help viewer could not serve (#2649).

### Removed

- Unused code, dependencies (`uniq`, `muzak`) and schema mappings left over
  from the hosted service: the `users` conversation-view preference fields and
  `sandboxes.provider_instance_id` are no longer read. Their columns are
  dropped in a later release (#2649).
