### Fixed

- **Claude Code's first start in a new sandbox no longer waits on its
  non-essential network traffic** (#2501). Sandboxes now run it with
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, and its start inside a new
  session took 1.1–1.3 s in production where it had taken up to 3 s. The
  median time to a new conversation's first reply did not move. This comes
  from `managoat_runtimes` 0.5.3.

### Upgrade notes

- **Claude Code in sandboxes no longer sends telemetry or error reports to
  Anthropic, and its `/bug` command and auto-updater are off** (#2501). The
  auto-updater was already moot, since the version is pinned. An environment
  that sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` itself still decides.
