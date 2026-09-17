### Changed

- Building a computer for a conversation is now done by one Fountain process at
  a time (#2344, ADR 0058). Fountain sometimes ends up with two processes for
  one conversation — a rolling deploy and a lost node both produce them — and
  until now both would build a computer, one of them billed for and unreachable.
  The second now finds the first already at work and stands down without
  touching anything.

- Building a computer now appears in that account's activity trail, as
  `sandbox.provisioned` when it comes up and `sandbox.provision_failed` when it
  does not (#2344). Until now the trail began at the first turn, and a computer
  that never came up left no trace in it at all.

- A build that is interrupted part-way — a deploy, a lost node — is now tidied
  up more reliably (#2344). Fountain has always torn down a half-built computer
  before building again, because the steps cannot be repeated on top of
  themselves, but it could only recognise one of the two ways a build stops
  part-way. It now recognises both.

- A prompt that arrives while a computer is being reset or deleted no longer
  wins that race (#2344). A reset or deletion asked for while the computer was
  still being built used to be overwritten at the last step, leaving the
  conversation holding a computer that was about to be deleted. The build now
  stands down, tears down what it made and leaves the reset or the deletion to
  finish. Deletion is new here: only a reset used to be checked.

- Replacing an agent's own computer when its disk is gone can now answer
  "unavailable, try again shortly" (#2344). Fountain retires the old computer
  before building the replacement, because an agent has one of them at a time;
  if something else is in the middle of an operation on it, that retirement now
  waits its turn and can be refused, and the answer is the ordinary
  `503` with a `Retry-After` rather than a database constraint error.

- A conversation whose computer the provider says is gone now retires that
  computer the same way every other ending does, and its record says
  `terminated` rather than `failed` (#2344). Both mean the same thing to
  everything that reads it — the computer is gone and the next prompt builds a
  fresh one — and the change is that the retirement is now one operation with
  one entry in the activity trail, rather than a status written in passing. On
  the admin computers page such a row now shows a grey `terminated` badge where
  it showed a red `failed` one, and the reason is in the trail.

- A conversation that cannot record its computer as reattached no longer
  restarts in a loop (#2344). An unexpected database failure at that moment
  used to crash the conversation's process, which was then restarted into the
  same failure; it now stops cleanly, releases what it was holding, and the next
  prompt tries again.

- A conversation that reattaches to a computer Fountain had parked now records
  that wake in the activity trail, as `sandbox.resumed` (#2344). It was already
  recorded for billing; it was missing from the trail, in the same way waking
  was before this series.

- The absolute thirty-minute ceiling on building a computer is unchanged, and
  now lands a little over a minute later than it used to (#2344). Fountain holds
  a computer for the length of the operation working on it, and the ceiling
  waits for that hold to run out before it retires the record — so that a
  computer is never retired out from under a process that is still building it.
  A build Fountain cannot retire at the ceiling is asked again a few times over
  the following minutes, and only then is its process stopped — so a record that
  cannot be written does not keep a computer reserved indefinitely, and a
  process is never restarted onto a computer that is still marked as building,
  which is what used to make a second computer get built.

### Fixed

- A failed start no longer leaves a computer reserved against the account's
  limit when only part of it could be cleaned up (#2344). When a conversation's
  process will not start at all, Fountain marks the conversation and its
  computer failed; the two are now done in an order where an interruption
  between them leaves the conversation to repair itself on its next prompt,
  rather than leaving a reserved computer nothing would collect for an hour.
