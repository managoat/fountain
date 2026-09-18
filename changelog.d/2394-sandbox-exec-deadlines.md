### Fixed

- Sprites and E2B commands with finite execution timeouts no longer extend
  their local output-collection deadline when stdout or stderr keeps arriving
  (#2394). This dependency update also makes explicit Sprites force termination
  available for follow-up work; it does not yet coordinate file reads with
  park/delete or confirm remote command termination after a local timeout.
