### Fixed

- **A flag that gates a built feature now says so when PostHog is not
  evaluating it** (#2347). `Fountain.FeatureFlags` fails closed, so a flag
  missing from PostHog's answer read exactly like a flag deliberately turned
  off, and silently switched the feature off for every account. A flag being
  evaluated comes back in the answer even when it says no, so Fountain now
  logs an error naming the flag when one it treats as built is absent, once
  per minute. The log says what was observed rather than guessing a cause:
  no flag has that key, a flag has it and is switched off, or its evaluation
  runtime excludes the call. An answer PostHog marks as incomplete, one kept
  from before an outage, and a failed lookup are never used to draw that
  conclusion. It still fails closed; nothing about who has a feature changes.
