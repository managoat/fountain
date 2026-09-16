### Changed

- A prompt that wakes a computer, and an attach that opens a conversation on
  one, now answer `503 sandbox_unavailable` with a `Retry-After` header while
  Fountain is in the middle of an operation on that computer (#2344, ADR 0058).
  Deleting a computer, resetting one and — shortly — parking an idle one each
  take the computer for the length of one provider round trip, and a wake that
  arrived during that used to race it. Send the request again: each SDK reports
  this as a not-ready error, the launch queue puts the start back in line, a
  team schedule waits and fires again inside its window, and the boot sweep
  leaves the computer to the operation that holds it. A computer being reset
  still answers `409 sandbox_reset_pending`, which says more.

- An attach that lands in the moment between Fountain taking a computer for a
  teardown and the teardown blocking new work is now refused as well (#2344,
  ADR 0058). Until now such an attach could win by a fraction of a second, and
  the teardown would find a conversation on the computer and stand down. The
  computer is taken once, and the retry lands on a settled one.

- A schedule that could not run because its teammate's computer was mid-operation
  now says so on the schedule — "teammate's computer was being started or
  stopped" — instead of giving up on the firing (#2344).

### Added

- A computer records when a conversation server was last started on it (#2344,
  ADR 0058). Nothing is shown for it and no request reads it: it exists so
  Fountain's cleanup pass can tell a computer somebody just woke from one that
  was abandoned, on any replica, without waiting for the cluster registry to
  catch up. Reclaiming an abandoned computer is unchanged, including its
  timing.
