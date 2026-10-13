### Fixed

- **A wake no longer trips over the network policy request's late answer**
  (#2559). On a sprite booting from cold, Sprites answers the policy request
  only once the machine is up, which can take longer than the 30 s client
  timeout. The retry then read the first attempt's late `204` off the pooled
  connection and failed with a `CaseClauseError`, and the earlier fix (#2571),
  which ran each attempt in its own process, didn't prevent it.
  `managoat_sandbox` 0.5.2 gives this one request 90 s, so the first attempt
  waits out the boot. The per-attempt process from #2571 is removed.
