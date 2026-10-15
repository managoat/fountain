### Changed

- **A permission policy that asks now applies to codex agents** (#2708).
  When the effective policy has any `ask` or `auto_deny` verdict, Fountain
  starts codex in its `read-only` ("Ask for approval") mode, so a write
  outside the workspace, network access and an escalation reach the policy
  instead of codex's own automatic reviewer. Writes inside the workspace
  still run without asking. A refused request ends the codex turn as
  `cancelled` (recorded `failed`), because codex offers no option that
  declines one call, and the next prompt continues the conversation. Under
  such a policy Fountain's mode replaces an environment's
  `INITIAL_AGENT_MODE`, `agent-full-access` included. A policy that allows
  everything keeps codex's `agent` mode as before. An open adapter
  connection started under a different policy is now restarted before the
  next turn, so a changed agent policy reaches running conversations. See
  [codex](https://managoat.com/docs/catalog/runtimes/codex#the-sandbox-codex-builds-for-itself).
