### Fixed

- **The deployed suite's `secrets` profile can pass** (#1614). It had never
  passed against a real deployment, and three checks it had never reached were
  stale:
  - it required curl exit 56 for a blocked destination, where current curl
    reports the same refused `CONNECT 403` as exit 7;
  - it required the binding placeholder to appear unredacted in durable output,
    which Fountain's redaction of every sandbox environment value rules out;
  - it located the allowed egress row by URL path, which the broker has stored
    as `/[REDACTED]` since #2132.

  Each now checks the signal that actually carries the meaning — the proxy's
  CONNECT answer, the script's own completion, the per-run receiver hostname —
  and none of the substituted evidence was already unproven elsewhere. A missing
  durable-output marker now names which one is missing.
