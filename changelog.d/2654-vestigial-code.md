### Changed

- The `Sandbox images` workflow's manual dispatch takes a `rebuild` boolean in
  place of the `providers` choice (#2654). `false` runs the Dockerfile check
  alone, as `none` did.
- The Hermes plugin no longer describes an HTTP 402 as a missing
  subscription; Fountain never returns one (#2654).
