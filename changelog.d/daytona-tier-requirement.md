### Changed

- The Daytona page says a deployment with the credential broker needs a Daytona
  organization on Tier 3 or higher. On Tier 1 and 2, Daytona refuses the
  per-sandbox network policy Fountain sets, so every provision fails at the
  `network` stage (without the broker, only `limited` environments do). The hosted
  instance stopped offering Daytona on 2026-10-06 for this reason.
