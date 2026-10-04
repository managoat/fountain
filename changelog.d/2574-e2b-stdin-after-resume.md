### Fixed

- **E2B conversations work again after their sandbox is parked** (#2574).
  After an E2B sandbox was paused and resumed, every turn failed at once with
  `acp_write_failed, :command_exited`: envd stopped finding processes by tag,
  so the first message to the newly started agent was refused.
  `managoat_sandbox` 0.5.1 addresses the process by its pid.
