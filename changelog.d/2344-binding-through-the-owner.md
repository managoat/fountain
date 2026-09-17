### Changed

- Opening a conversation on an existing computer, and ending one, are now
  done by the process that owns that computer (#2344, ADR 0058). An attach or
  a terminate that arrives while the computer is being parked, woken, rebuilt
  or deleted used to be refused at once (an attach) or to fence the computer
  underneath the operation and leave it for an hourly cleanup pass to finish
  (a terminate). Now a terminate waits up to five seconds for the operation to
  finish — up to twenty with `MACHINE_OWNER_ENABLED` set, where both queue
  behind it — and, if it has not, answers the ordinary `503` with a
  `Retry-After` (`sandbox_unavailable`) and leaves the computer alone; an attach
  still answers that at once without the setting and queues with it. Where no
  server was left driving the conversation, the conversation itself is already
  closed by the time the computer refuses, and sending the request again — what
  the `Retry-After` asks for — finishes the computer and records the
  termination. An attach or a terminate the owner reaches only after its caller
  has given up is refused rather than run for nobody, and so is a wake.

- Opening a fresh conversation for a teammate on the computer it already has
  now goes through the same door as attaching by `sandbox_id` (#2344): the
  computer must still be the one built for that agent, environment and vault,
  must not be reset, deleted or mid-operation, and the new conversation gets
  an execution allowance like every other. The computer is asked *before* the
  current conversation is retired, so a computer that refuses costs the
  teammate nothing — the request answers `409` while the computer is being
  reset or deleted, `503` while an operation holds it, and the teammate keeps
  the conversation it had, so the same request can simply be sent again. An
  agent whose environment, vault or runtime has changed since its computer was
  built is now refused (`422`) rather than given a new session on a disk built
  for something else; that teammate needs a conversation of its own rather than
  a fresh one on the same computer.

- When a computer is deleted, every turn still running on it is now marked
  interrupted by the deletion itself (#2344), on every conversation bound to
  it, rather than left `running` until a later process happened to notice.
  Each such conversation's stream records the turn as interrupted with the
  reason `machine_destroyed`, and its trail records `conversation.turn.orphaned`.
  A computer parked at its maximum-lifetime ceiling now ends the turn the
  ceiling cut the same way (`machine_parked`); a computer parked while idle
  still leaves a turn nobody is driving where it is, so a request waiting on
  a person's answer stays answerable.

- A computer held by a Fountain server that has disappeared from the cluster
  is released sooner (#2344). Fountain holds a computer for the length of one
  operation and extends the hold while the work continues; a server that died
  mid-operation used to keep the computer for the rest of its hold, up to two
  minutes. A hold whose owner is not a connected server *and* has stopped
  being extended is now taken over as soon as it has run down past the point
  a live owner would have extended it. A server that is merely cut off from
  the others keeps extending its hold and is left alone.

- The provider identity binding that no code path recorded is gone (#2344):
  `sandbox.provider_identity_bound` was an event nothing could produce.

### Fixed

- One computer that refuses to be written no longer stops the hourly pass that
  releases computers stuck mid-provision for every computer after it (#2344,
  #2329). The refused one is logged and left for the next pass.
