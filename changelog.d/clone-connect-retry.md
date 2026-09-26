### Fixed

- **A repository clone that fails to connect is retried** (#1684). On
  Sprites, the first connection through a newly applied broker network policy
  is sometimes refused. About 2 in 5 fresh provisions that install packages
  and then clone a repository failed with `Could not connect to server` and
  never started. Fountain now retries a clone that never reached the remote,
  up to three attempts in total. That clone wrote nothing, so retrying it is
  safe. Any other clone failure still fails the provision on the first
  attempt.
