### Changed

- The periodic backstops run as one Oban worker (#2640).
  `Fountain.Workers.SandboxReaper` now also reaps turns left running with no
  server (on its five-minute `teardowns` run) and denies detached permission
  requests past their deadline (a one-minute `detached_requests` run). The
  `AutonomousTurnReaper` and `DetachedRequestSweeper` workers are gone, so
  Oban job metrics and `oban_jobs` rows for that work carry the
  `SandboxReaper` worker name. The cron table has one fewer entry. Audit actors and
  telemetry events are unchanged.
