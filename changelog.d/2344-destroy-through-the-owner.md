### Changed

- Terminating a conversation whose server is no longer running now destroys its
  computer straight away, instead of retiring the row and leaving the machine
  for the reaper's next pass to collect (#2344, ADR 0058). A shared computer or
  an agent's persistent home is still kept, exactly as before. The reaper still
  sweeps up anything a destroy could not finish.

### Added

- `sandbox.destroyed` on the audit trail: one event per computer actually torn
  down, carrying who asked, why, and which provider it was on (#2344,
  ADR 0058). The `sandbox.teardown_requested` event that records the *intent*
  is unchanged, so a teardown that was requested and never completed still
  reads as exactly that.
