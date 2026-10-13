### Upgrade notes

- **The `fountain-fixture` test runtime is removed** (#2630).
  `DEPLOYED_ACP_FIXTURE_ENABLED` and `DEPLOYED_ACP_FIXTURE_USER_ID` are no
  longer read. An agent that still names `fountain-fixture` is refused at
  launch as an unsupported runtime; change its runtime or delete it.

### Removed

- The deployed-instance verification suite (`deployed/`) and
  `scripts/verify-deployment.sh` are removed (#2630).
