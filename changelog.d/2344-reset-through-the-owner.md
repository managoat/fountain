### Changed

- Resetting a computer now goes through the one owner that every other
  teardown of it goes through (#2344, ADR 0058). Nothing about what a reset
  does has changed: it still blocks new turns first, still keeps the
  conversations and their transcripts, still holds the computer's capacity
  until the provider confirms the deletion, and still records
  `sandbox.reset_requested` when it starts and `sandbox.reset` when it
  finishes. What changed is that a reset, an automatic retry and an
  administrator's retry of the same computer can no longer be at the provider
  at the same time. One of them holds the computer, the others wait or stand
  off, and the computer is deleted once. `DELETE /api/sandboxes/:id` can
  therefore answer `503 sandbox_unavailable` when another teardown of that
  computer is running. The reset is still accepted: the computer is fenced
  before that answer and Fountain completes the reset on its own, so sending
  the request again reports the reset already pending rather than starting a
  second one. The admin panel's **Retry reset** says the computer is busy
  rather than reporting the fence as cleared.

- A provider client that raises while a reset is deleting a computer no longer
  takes the caller down with it (#2344, ADR 0058). It reads as what it is — a
  deletion the provider did not confirm — so the fence and the capacity stay
  reserved and the automatic retry picks the computer up, which is what a
  provider *error* has always done.

- Stopping the compute of a released or expired claimable principal records the
  sweep that asked for it on every computer it destroys (#2344, ADR 0058).
  `sandbox.destroyed` used to say `self` for a computer whose conversation
  still had a live server and `system:principal_sweep` for the rest, so who a
  teardown was attributed to depended on whether a process happened to be
  running. Closing an account is unaffected: it records no `sandbox.destroyed`
  at all, and its teardown requests already named the operator.

- A completed reset records whoever asked for it (#2344, ADR 0058). When a
  reset and Fountain's automatic retry of the same reset met, the retry used to
  finish the work and `sandbox.reset` was attributed to it; the caller now
  finishes its own reset and the trail says so. A reset the automatic retry
  really does complete on its own still names the retry.
