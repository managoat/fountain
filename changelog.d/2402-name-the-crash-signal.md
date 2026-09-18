### Changed

- **A turn that a native crash ended names the signal** (#2402). The `turn`
  stage event that ends such a turn carries `signal` (for example `SIGSEGV`)
  next to `exit_code`, for exit codes 132 to 136 and 139. Other exit codes are
  unchanged. Read
  [The agent runtime crashed](https://managoat.com/docs/troubleshooting/conversation-stuck-or-failed#the-agent-runtime-crashed).
