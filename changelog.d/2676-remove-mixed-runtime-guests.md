### Upgrade notes

- **Mixed-runtime sandboxes are destroyed on upgrade** (#2676). A migration
  ends every conversation of another agent attached to a persistent sandbox,
  and marks every live sandbox that ever carried one for destruction; the
  reaper's teardown run destroys it within about five minutes. The sandbox's
  own agent's conversations stay, and their next prompt builds a fresh
  sandbox. Until the destroy finishes, a prompt to them answers
  `409 sandbox_reset_pending`. To rule out a replica of the previous release
  attaching a new guest during a rolling deploy, stop the old replicas first.

### Removed

- **Mixed-runtime guests** (#2676). A conversation of another agent can no
  longer attach to a persistent sandbox with `sandbox_id`: it gets
  `422 sandbox_identity_mismatch`, whatever its runtime and whatever key made
  the request. `403 guest_attach_requires_full_scope` and the reapply refusal
  `409 rebuild_required` with `field: "guest"` are gone with it.
