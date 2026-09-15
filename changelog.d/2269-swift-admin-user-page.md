### Added

- Swift SDK: `AdminUserListResponse` and its nested `Meta` are generated from
  the contract, so the `/api/admin/users` page-number envelope has one typed
  definition (#2269).

### Changed

- Swift SDK: `AdminUserPage` decodes that envelope rather than declaring the
  `data` / `meta` / `page` / `per_page` / `total` keys a second time (#2269).
  Its public surface is unchanged: `users`, `page`, `perPage`, `total` and the
  computed `hasMore`.
