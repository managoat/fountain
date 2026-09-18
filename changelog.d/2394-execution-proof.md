### Changed

- Added provider and runner diagnostics for the sandbox-files lifecycle
  investigation, including a live Sprites descendant-termination counterexample,
  reproducible timeout gaps and an implementation handoff.
  The live probe attempts identity-checked cleanup if post-create bookkeeping fails.
  This does not change file-read behavior or fix #2394.
