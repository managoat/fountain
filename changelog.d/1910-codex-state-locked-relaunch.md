### Fixed

- **A Codex turn is no longer failed outright when Codex cannot open its local
  state** (#1910). Codex conversations on one sandbox share one SQLite state.
  During a burst of turns, a new Codex process could give up waiting for the
  lock and exit before your prompt was sent. The turn then failed with
  `failed to initialize sqlite state runtime`. The runtime is now started again
  up to three times, after pauses of about 2–4, 6–12 and 15–30 seconds. Each
  restart shows on the stream as a `session` stage event with `reason:
  "runtime_state_locked"`. The turn fails with the original error only if all
  three restarts fail too.
