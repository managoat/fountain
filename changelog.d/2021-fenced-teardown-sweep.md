### Fixed

- The sandbox reaper now finishes a teardown that fenced and then died before
  its terminal write. Such a row was invisible to every reaper pass while it
  went on consuming a tenant's concurrent-sandbox slot and a fleet slot, with
  the machine still billing at the provider (#2021).

### Added

- `fountain.reaper.run.reconciled` counts those abandoned teardowns. Unlike the
  reaper's other counters a non-zero value is not routine reclamation — it says
  a teardown died halfway and the machine leaked until the reaper found it
  (#2021).
