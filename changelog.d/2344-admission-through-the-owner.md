### Changed

- A turn is now admitted onto a computer by the process that owns that
  computer, and it is refused while another operation is in flight on it
  (#2344, ADR 0058). A prompt that arrives while the computer is being parked,
  woken, rebuilt or deleted used to start a turn against a machine that was
  about to change under it; it now waits up to five seconds for the operation
  to finish and, if it has not, answers the ordinary `503` with a `Retry-After`
  (`sandbox_unavailable`) rather than starting. An operation whose owner died
  part-way does not hold the computer: the turn is admitted as before.

- A prompt on a computer that is being deleted is refused (#2344). A computer
  whose deletion had been asked for still accepted a new turn until the
  deletion finished, and the turn then died with it; a reset already refused
  in the same place. Both now answer `503` `sandbox_unavailable`.

### Fixed

- Turn capacity on a shared computer is counted per runtime (#2344, #1089).
  Runtimes that take one turn at a time — `opencode`, `gemini` — had every
  running turn on the computer counted against them, whatever runtime it ran
  on, so a `claude` conversation working on a shared computer stopped an
  `opencode` conversation on the same computer from starting a turn. A turn
  now counts only against conversations on the same runtime; a second
  `opencode` turn is still refused with `409` `sandbox_at_capacity` while the
  first runs.
