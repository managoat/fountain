### Fixed

- During a deploy, a server that has begun shutting down no longer takes new
  conversations, so a turn is not started on a pod that is about to stop
  (#2594).
