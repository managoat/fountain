### Fixed

- A turn no longer fails when the agent runtime crashes while starting
  (#2402). If a native crash (such as SIGSEGV) kills the adapter before it
  writes any output, Fountain starts it once more under the same turn. No
  prompt was sent before the crash, so the retry cannot run the prompt twice.
  The transcript records a `session` stage with `event: "restarted"` and
  `reason: "adapter_crashed"`. A second crash fails the turn with its exit code,
  as before. Turns with execution limits are not retried.
