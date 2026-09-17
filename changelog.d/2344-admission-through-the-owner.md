### Changed

- A turn is now admitted onto a computer by the process that owns that
  computer, and it is refused while another operation is in flight on it
  (#2344, ADR 0058). A prompt that arrives while the computer is being parked,
  woken, rebuilt or deleted used to start a turn against a machine that was
  about to change under it; it now waits for the operation to finish — up to
  five seconds, or up to twenty with `MACHINE_OWNER_ENABLED` set, where the
  prompt queues behind the operation — and, if it has not finished, answers
  the ordinary `503` with a `Retry-After` (`sandbox_unavailable`) rather than
  starting. An operation whose owner died part-way does not hold the computer:
  the turn is admitted as before.

- A prompt to a conversation whose computer is being deleted is refused
  (#2344). While the conversation's process was still up, a computer whose
  deletion had been asked for accepted a new turn until the deletion finished,
  and the turn then died with it; a reset already refused in the same place.
  Such a prompt now answers `503` `sandbox_unavailable`. Once the
  conversation's process is gone — the usual state a little later, and the
  state of every parked neighbour — the prompt wakes the conversation instead,
  and that door answered `409` `sandbox_reset_pending` before this change and
  still does.

- Turn capacity on a shared computer is now counted per runtime (#2344;
  groundwork for #1089). Runtimes that take one turn at a time — `opencode`, `gemini` —
  had every running turn on the computer counted against them, whatever
  runtime it ran on. A turn now counts only against conversations on the same
  runtime, and a second `opencode` turn is still refused with `409`
  `sandbox_at_capacity` while the first runs. Today every conversation on a
  computer runs the same runtime (attaching a different one is refused with
  `422` `sandbox_runtime_mismatch`), so nothing a user can do today produced
  the wrong count; #1089, two agents on one computer, is what would have.
