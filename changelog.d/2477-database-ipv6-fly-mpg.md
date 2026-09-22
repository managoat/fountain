### Added

- **`DATABASE_IPV6=true` connects to Postgres over IPv6** (#2477). The shipped
  `fly.toml` sets it, because Fly Managed Postgres's `*.flympg.net` host
  resolves to a private IPv6 address only. Without it, an instance deployed by
  the Fly guide cannot find its database and exits at boot with `:nxdomain`.
