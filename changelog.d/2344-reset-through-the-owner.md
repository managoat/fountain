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
  therefore answer `503 sandbox_unavailable` with a `retry-after` when another
  teardown of that computer is running; the reset fence stays in place, so
  retrying is safe and Fountain retries on its own. The admin panel's **Retry
  reset** says so rather than reporting the fence as cleared.

- A provider client that raises while a reset is deleting a computer no longer
  takes the caller down with it (#2344, ADR 0058). It reads as what it is — a
  deletion the provider did not confirm — so the fence and the capacity stay
  reserved and the automatic retry picks the computer up, which is what a
  provider *error* has always done.

- Closing an account records the operator or the sweep that asked for it as
  the actor on both of each computer's teardown events, whether or not that
  computer's conversation still had a live server (#2344, ADR 0058).
  Attribution used to depend on which of the two paths a computer took, so the
  same operation recorded `admin:<id>` for some of a tenant's computers and an
  anonymous `self` for others.
