### Added

- `POST /api/admin/users` opens an account for a platform built on the
  instance: verified, with no password, and returned with one full-scope API
  key, shown once. Registration's gates (`REGISTRATION_ENABLED`, the access
  code, the domain list) don't apply, because the admin pipeline in front of
  it is the gate. Audited as `account.created_by_admin`, `api_key.created` and
  the admin trail's `admin.account.created` (ADR 0064).
