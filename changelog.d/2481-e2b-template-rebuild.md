### Fixed

- The Sandbox images workflow can rebuild and smoke the E2B template (#2481).
  The repository had no `E2B_API_KEY`, so the job had never run. Its smoke
  step also passed `-lc` to the e2b CLI instead of to `bash`, and left stdin
  open for the CLI to wait on.
