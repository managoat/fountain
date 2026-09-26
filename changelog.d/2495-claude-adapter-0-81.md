### Added

- **Claude Opus 5.5 (`anthropic/claude-opus-5-5`) is a suggested model**
  (#2495). Platform-key turns on it are priced at Anthropic's list rates. Opus 5
  (`anthropic/claude-opus-5`) stays available, and agents set to it keep it.

### Fixed

- **Claude conversations on a Claude.ai subscription token wake and
  provision about 30 seconds faster** (#2495). Since 2026-09-12, sandbox setup ran a
  model-list warm-up that could only succeed on an Anthropic API key. On a
  subscription token it waited out its 30-second limit on every cold start
  and every wake, which put the median wake at 36 seconds. The newer Claude
  adapter lists every model itself, so the warm-up is gone.
- **Claude Fable 5.1 works on a Claude.ai subscription token, and on a
  sandbox's first conversation** (#2495). Before, those turns failed with
  "Invalid value for config option model".
- **Platform-key turns on Claude Fable 5.1 are priced at Fable's rate**
  (#2495). They were priced at the Opus rate, half their cost.

### Changed

- **The Claude adapter moves to claude-agent-acp 0.81.2** (#2495). Its `opus`
  alias now means Opus 5.5, so an agent set to the bare `anthropic/opus`
  model runs on Opus 5.5 rather than Opus 5. Existing sandboxes install the
  new adapter the next time they wake or start a turn.
