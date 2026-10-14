### Upgrade notes

- **Breaking: the admin API needs an admin key** (#2660). `/api/admin/*`
  now requires a key with the new `admin` scope as well as the admin role.
  Every key that exists today, including a platform provisioner's (ADR 0064),
  is refused with `403` and `error: "admin_key_required"` once you upgrade.
  Before or right after upgrading, mint an admin key as the admin on
  **Account → API keys** with **Admin key** checked, or with
  `bin/fountain_server eval 'Fountain.Release.create_admin_key("ops@example.com", "provisioner")'`.
  Put it where the old key was, then revoke the old key. See
  [Admin](https://managoat.com/docs/api#admin).

### Security

- Admin powers no longer travel with every full-scope key an admin holds
  (#2660). The key an app gets from Sign in with Fountain, the key
  `fountain auth login` gets from `POST /api/auth/token`, and keys minted at
  `POST /api/auth/api-keys` never carry the `admin` scope, so an app or
  terminal an admin signs into cannot create, re-role, suspend or delete
  accounts. Demoting an admin stops their admin keys working.
