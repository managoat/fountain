### Upgrade notes

- **Registration now closes once the instance has an admin** (#2673).
  `REGISTRATION_ENABLED` defaults to `auto`: self-registration stays open
  only until an admin exists. An instance that left the variable unset and
  wants signup open set it to `true`. Values other than `true`, `false` or
  `auto` refuse to boot. Admins still open accounts through
  `POST /api/admin/users`.

### Security

- A default install no longer lets strangers register, self-verify and run
  the starter agent on the platform inference keys (#2673).
- `FIRST_USER_ADMIN` no longer re-arms: once any admin has existed it never
  promotes another account, even after that admin is demoted or deleted
  (#2673).

### Fixed

- Auto-verified registration (`EMAIL_DELIVERY=none`) writes its audit rows,
  the first-admin grant and the starter agent after the account commits, so a
  failed audit write can no longer roll back the signup (#2673).
