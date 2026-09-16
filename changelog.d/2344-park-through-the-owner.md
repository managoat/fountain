### Changed

- Parking an idle computer is now done by one Fountain process at a time, and
  it takes the computer for the length of that operation (#2344, ADR 0058).
  Until now a computer could be parked by the conversation using it and by
  Fountain's hourly cleanup pass at the same moment, each having decided it was
  idle a little earlier, and neither knowing about the other. A prompt or an
  attach that arrives while a park is in flight answers
  `503 sandbox_unavailable` with a `Retry-After` header; send it again and it
  lands on a computer that has settled, which for a parked computer means it is
  woken and carries on with everything it had.

- A computer parked by the conversation on it now appears in that account's
  activity trail as `sandbox.suspended`, the same entry Fountain's cleanup pass
  has always recorded (#2344). The two paths park a computer for the same
  reason and are now the same operation, so "where did my computer go" has the
  same answer whichever of them noticed first.

- Deciding not to park is now decided once, when the computer is taken, rather
  than by each caller beforehand: a computer whose provider cannot park it, or
  whose park the provider refuses, is reclaimed instead, exactly as before
  (#2344). A computer somebody else is working on, or one already being reset
  or deleted, is left alone.

- A park interrupted part-way — a deploy, a lost node — is now finished or
  undone on the next cleanup pass (#2344, ADR 0058). Fountain asks the provider
  what actually happened to the computer: if it was parked, the park is
  completed; if it is still running, the interrupted park is cleared and the
  computer goes on as it was until it next falls idle. It is never both.

### Fixed

- Fountain's cleanup pass can no longer park a computer that a prompt has just
  woken (#2307, #2344). Its decision that a computer was idle was made before
  it began, and nothing re-checked it: a prompt landing in between could find
  its computer suspended out from under it, or leave the row saying `ready` for
  a computer that had been parked. Every condition the decision rested on — who
  is on the computer, whether a turn is running, whether a wake has just
  started a session on it, and how long it has been quiet — is now re-read at
  the moment the computer is taken, and the park stands down if any of them has
  changed.
