### Fixed

- **A wake no longer crashes on a late network policy answer** (#2559). On a
  waking sprite, Sprites answers the network policy request only once the
  machine is up. When that took longer than 30 s, the retry read the first
  attempt's late answer as its own and failed with a `CaseClauseError` before a
  third attempt succeeded. Each attempt now runs in its own process, so a late
  answer is dropped.
