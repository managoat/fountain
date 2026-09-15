# Troubleshooting

Start from the symptom you can see. Each page names the symptom, says what
causes it, and says what to run.

[Architecture](../architecture.md) tells you which component owns a symptom.
These pages are the action level. They say what to run, and what the output
means. Where the two deploy paths differ, both commands appear.

## By symptom

| You see | Read |
|---|---|
| A conversation sits in `running` with no output, or it went `failed`. | [A conversation is stuck or failed](conversation-stuck-or-failed.md) |
| A sandbox fails to start while the rest of the system is healthy. | [Sandbox errors](sandbox-errors.md) |
| A turn fails and says your organization disabled subscription access. | [Which credential claude uses](../catalog/runtimes/claude.md#which-credential-it-uses) |
| A codex agent cannot write outside its workspace, or cannot reach the network. | [The sandbox codex builds for itself](../catalog/runtimes/codex.md#the-sandbox-codex-builds-for-itself) |
| Pods restart, or they sit NotReady. | [Pods restart or never go ready](pods-restarting.md) |
| Registration completes, but nobody gets past "check your email". | [Nobody can log in](nobody-can-log-in.md) |
| Fountain rate-limits everyone at once. | [Nobody can log in](nobody-can-log-in.md) |
| A rollout never completes. | [Upgrade an instance](../guides/operate/upgrade.md) |
| You need a restore. | [Back up and restore](../guides/operate/back-up-and-restore.md) |

## Problems on the client side

Sometimes the failure is in the thing that drives Fountain, and not in
Fountain. Each client's own page carries its failure modes.

- [`fountain acp`](../integrations/acp.md), the adapter that editors and chat
  surfaces spawn.
- [Editors](../integrations/editors.md).
- [OpenClaw](../integrations/openclaw.md).
- Buzz.

## A workstation that will not start

A problem with a local development checkout belongs in
[Setup](../setup.md), and not here.
