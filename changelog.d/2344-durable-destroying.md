### Changed

- A computer somebody has asked Fountain to delete now stays refused until it
  is actually gone (#2344, ADR 0058). Deleting a computer records the request
  on it and then does the work; if the Fountain server doing that work died in
  between, the request used to be readable as an operation that had been
  abandoned, and the next prompt, boot or attach would clear it and carry on
  using the disk. Now every one of those doors refuses such a computer — with
  the `409` it already answered for a computer being reset — and leaves the
  request where it is. The computer still counts against your concurrent
  computer limit until it is gone, because until then it exists and is billed.
  A conversation on it is not stranded: the next prompt builds a fresh
  computer, exactly as it did while the deletion was in flight.

### Fixed

- An abandoned deletion is now finished properly rather than half-finished
  (#2344, #2021). The hourly pass that cleans these up used to mark the
  computer deleted in Fountain and leave the machine at the provider for a
  later pass; it now deletes the machine on the same run, through the same door
  every other deletion goes through. So the trail records `sandbox.destroyed`
  with the same reason the original request gave — the reason the deletion
  recorded on the computer when it started, not a generic one — beside the
  `sandbox.teardown_reconciled` that says the pass had to finish it, and the
  usage record closes at the moment the computer really stopped. A computer the
  pass cannot reach is counted in the run's `refused` total and left for the
  next run.

- A computer whose deletion was abandoned is no longer left behind indefinitely
  on a busy instance (#2344). The hourly reaper spends one allowance of
  provider deletions per run, and ordinary expiries could consume all of it
  before the abandoned deletions were reached — so on an instance with a
  standing backlog of expiring computers, an abandoned deletion of an
  *ephemeral* computer had no route to completion at all: it kept billing, kept
  holding a slot against your concurrent computer limit, and answered `409` to
  every prompt. A small part of each run's allowance is now reserved for
  finishing them, so a backlog delays that work rather than preventing it.
