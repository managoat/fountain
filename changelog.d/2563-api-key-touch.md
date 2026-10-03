### Changed

- **An API key's `last_used_at` is updated at most once a minute** (#2563).
  Every authenticated request used to write the key's row, and parallel
  requests on one key waited on each other for it, up to 2.7 s each while
  holding a database connection. The stamp can now be up to a minute behind
  the key's latest use.
