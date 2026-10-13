### Fixed

- A parked sandbox's file snapshot is no longer dropped when the agent has
  changed many files (#2591). The capture's file list no longer goes in the
  exec request, which Sprites refused with 414 on most parks, leaving the
  sandbox's files "not ready" until it woke.
