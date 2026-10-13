### Upgrade notes

- **The support-report extension is removed** (#2606). `GET/POST
  /api/support/reports` and `GET /api/support/reports/{id}` are gone, and a
  migration drops the `support_reports` table with its rows. Export any
  reports you need first. `SUPPORT_GITHUB_REPO` and `SUPPORT_GITHUB_TOKEN` are
  no longer read; `SUPPORT_EMAIL` still names the account emails' contact.

### Removed

- The scheduled deployed-instance verification workflow is removed (#2606).
  Run `deployed/` by hand or from your own CI; see
  [Deploy an instance](https://managoat.com/docs/guides/operate/deploy#run-after-a-rollout).
