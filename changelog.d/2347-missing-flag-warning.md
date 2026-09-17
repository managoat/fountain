### Fixed

- **A flag that gates a built feature now says so when it is missing from
  PostHog** (#2347). `Fountain.FeatureFlags` fails closed, so a flag key that
  no longer exists in the analytics project — or exists with its
  `evaluation_runtime` set to `server`, which a project-token evaluation never
  sees — read exactly like a flag deliberately turned off, and silently
  switched the feature off for every account. Fountain now logs an error
  naming the flag, once per minute, for the flags it treats as built. It still
  fails closed; nothing about who has a feature changes.
