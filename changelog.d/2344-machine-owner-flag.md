### Added

- **`MACHINE_OWNER_ENABLED`**, off by default (ADR 0058, #2344). The gate on
  the per-sandbox owner process, which will become the only writer of a
  sandbox's state. In this release the owner only reads: turned on, it starts
  one process per active sandbox that answers who is on that machine, and
  writes nothing. Leave it off.
