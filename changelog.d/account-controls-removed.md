### Upgrade notes

- **`REGISTRATION_ALLOWED_EMAIL_DOMAINS` and `REGISTRATION_ACCESS_CODE` are
  gone** (#2436). An instance that still sets them boots and ignores them;
  `REGISTRATION_ENABLED` is the one registration control. Remove both from
  your environment. `fountain auth register` no longer takes
  `--access-code`.

- **Account suspension is gone** (#287). `POST /api/admin/users/{id}/suspend`
  answers 404, and admin user rows no longer carry `suspended` or
  `suspended_at`. An account suspended before the upgrade is active again
  after it; delete the accounts you do not want. The `users.suspended_at`
  column is dropped in the following release.

### Removed

- Self-serve email change (#448): `POST /api/auth/email`,
  `POST /api/auth/email/confirm`, the `/account/email/confirm/:token` link
  and the form on `/account/security`. Password change stays.

- The `/auth/verify-pending` waiting page (#533). Signing in with an
  unconfirmed email address now stays on the login page, which says to open
  the emailed link or resend it, and no session is issued. The emailed link
  and `POST /api/auth/verify` work as before.
