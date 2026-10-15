### Upgrade notes

- **The fleet ceiling is now per provider** (#2667). Sprites and E2B
  sandboxes are counted separately, each against its own ceiling:
  `SANDBOX_FLEET_CEILING_SPRITES` and `SANDBOX_FLEET_CEILING_E2B`. Both default
  to `SANDBOX_FLEET_CEILING`, which still defaults to 20, so a deployment that
  sets none of the new variables keeps the same number per provider. The one
  difference is that a deployment running both providers can now have up to
  that many live on each, rather than that many in total. Set the per-provider
  variables to what each provider plan allows; see
  [Configuration](https://managoat.com/docs/configuration#sandbox-capacity).

### Changed

- A start or wake is refused with `503 fleet_full` only when the provider it
  would run on is full; a full Sprites fleet no longer refuses an E2B start,
  nor the reverse (#2667).
