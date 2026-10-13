### Added

- **`fountain_turn_first_update_elapsed_ms`** (#2564), the time from a turn's
  start to the agent's first visible update: text, thinking, a tool call or a
  plan. `fountain_turn_first_output_elapsed_ms` times the first bytes the
  runtime prints, which under ACP include the handshake, so it reads well under
  what a user waits.
