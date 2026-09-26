### Fixed

- **A new Claude conversation's first reply arrives about 1.5 seconds sooner**
  (#PRNUM). On a fresh sandbox, Claude Code's first start waited on its
  non-essential network traffic; sandboxes now run it with
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. This comes from
  `managoat_runtimes` 0.5.3.

### Upgrade notes

- **Claude Code in sandboxes no longer sends telemetry or error reports to
  Anthropic, and its `/bug` command and auto-updater are off** (#PRNUM). The
  auto-updater was already moot, since the version is pinned. An environment
  that sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` itself still decides.
