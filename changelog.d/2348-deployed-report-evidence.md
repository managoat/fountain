### Fixed

- The deployed-instance suite no longer corrupts its own report when a
  `secrets` run fails (#1612). Findings live under a key the credential
  heuristic matched, so the whole block was replaced with `[REDACTED]` and
  every string inside it — including a leak record's `transport: "sse"` —
  became a redaction token. A run then rewrote `passed` to `pa[REDACTED]d`
  in `result.json`, leaving check statuses outside their own enum and the
  failure counts in `junit.xml` wrong. The report now has registered secrets
  removed from its strings without the key-name guessing, which still applies
  to the responses an instance sends.
