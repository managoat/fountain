---
type: ADR
title: "An app reaches its own sandbox through Fountain, never with a provider token"
description: "Proposed, unbuilt: owner-scoped, audited API routes for commands, terminals, background processes and port tunnels on a caller's own sandbox, going through Fountain's wake and lease, so that no app holds a credential for the provider organization. Ravix's org-wide Sprites token is revoked once Ravix has moved."
tags: [api, sandbox, security, apps]
status: draft
adr: "0065"
adr_status: "Proposed"
date: 2026-10-07
---

# 0065 — An app reaches its own sandbox through Fountain, never with a provider token

**Status:** Proposed, 2026-10-07. Nothing described here is built. The open
questions at the end need answers before this is accepted.

## Context

[0005](0005-platform-shared-sprites-token.md) holds one platform credential for
the Sprites organization and says it is "never visible to tenants". A single
token compromise exposing every tenant's machines is that ADR's accepted
risk, and the platform's alone.

Ravix, the first app built on Fountain, holds a second one. Its `render.yaml`
says so: "Ravix reaches a machine's sprite with its own token, so that token
has to belong to the Sprites org the Fountain builds on." Checked on
2026-10-07:

- **It is a different token from Fountain's.** The two have different SHA-256
  fingerprints, compared without printing either value.
- **It reaches every tenant.** One read-only `GET /v1/sprites` with it listed
  500 sprites (with more pages) owned by 8 Fountain accounts. Only one of
  them is Ravix's.
- **Nothing narrower exists.** Fly's Sprites documentation describes tokens
  only per organization (`my-org/token-id/secret`). Connectors have access
  policies; API tokens have no scope by sprite or by operation. 0005 already
  recorded that Sprites has no per-tenant sub-accounts.

Ravix's code only touches its own account's sandboxes. It finds a sandbox's
machine name with `GET /api/sandboxes/:id` and then calls Sprites directly
for five things:

| Use in Ravix | Sprites API | Fountain today |
|---|---|---|
| One-off commands: preview-helper install, health probe, run scripts, terminal commands without a TTY (`Ravix.Sprites.exec/4`, `shell/5`) | `POST /v1/sprites/:name/exec` | none |
| Interactive terminal with reattach and kill (`Ravix.Sprites.Pty`) | exec WebSocket with `tty=true`, `/exec/:session_id`, `/exec/:session_id/kill` | none; `managoat_sandbox` has `spawn`, `attach`, `list_sessions`, `terminate_session` and a `:tty` capability (Sprites only) |
| Long-running preview and run processes (`define_service`, `service_action`, `service_logs`, `activity`) | `/v1/sprites/:name/services/*`, the in-machine `tasks` lease | none; no library equivalent |
| Preview traffic to a port inside the machine (`Ravix.Sprites.Tunnel`, `RavixWeb.PreviewGateway`) | `/v1/sprites/:name/proxy` WebSocket | none; no library equivalent |
| Is the machine up, without waking it (`running?/2`) | `GET /v1/sprites/:name` | `GET /api/sandboxes/:id` already answers this |

Because this runs outside Fountain:

- **Fountain cannot audit it.** None of these calls is recorded against the
  tenant that made them.
- **It bypasses Fountain's wake and lease.** A command sent straight to a
  parked sprite wakes it outside `Machines.Resume`
  ([0058](0058-the-machine-has-one-owner.md)), so Fountain's state and the
  machine's disagree. On 2026-10-07 this cost each of Ravix's first prompts to
  a parked thread ~10 s, serially (ravix-hq/ravix#496).
- **It is Sprites-only.** An app holding a provider token cannot follow a
  sandbox to E2B, Daytona or a runner.

## Decision

Fountain grows API routes that do each of those five things on a sandbox the
caller owns. Once they exist and Ravix uses them, Ravix's Sprites token is
revoked, and no app is given a provider credential again.

1. **Owner-scoped, full-scope routes under `/api/sandboxes/:sandbox_id`.**
   They use the same pipeline and ownership rule as the files routes
   ([0039](0039-sandbox-files-over-the-api.md)): a sandbox the caller does
   not own is `404`, and a sandbox's own `sprite` token cannot reach any
   other sandbox. A terminated or failed sandbox is `409`.
2. **They wake through Fountain.** Unlike the files reads (0039 decision 6),
   these act on a running machine. A request to a parked sandbox goes through
   `Machines.Resume` under the lease, like `POST /wake`
   ([#2585](https://github.com/managoat/fountain/pull/2585)), and answers once
   the machine is ready or with `409 sandbox_not_ready` and a wake in
   progress. A park waits on an open terminal, process or tunnel the same way
   it waits on a turn. Machine time is billed as for any wake.
3. **Commands.** `POST …/exec` takes `argv`, `cwd`, `timeout_s` and a bounded
   `stdin`, and answers `stdout`, `stderr` and `exit_code` with an output cap.
   It goes through `Managoat.Sandbox.exec/4`, so it works on every provider.
   The audit event records the argument count and never the arguments, the
   rule Ravix's own trace already follows.
4. **Terminals.** A WebSocket at `…/terminal` opens a TTY session, and
   `…/terminal/:session_id` reattaches to one and replays its output. It goes
   through `spawn`/`attach`/`terminate_session`. A provider without `:tty`
   answers `422 capability_unsupported`.
5. **Background processes and tunnels need library work first.**
   `managoat_sandbox` gains provider-neutral callbacks for a named,
   restartable process with logs and for a TCP stream to a port inside the
   machine, each behind a capability. Sprites implements them with its
   services and `/proxy` APIs; other providers say `capability_unsupported`
   until they can. Fountain's routes for them follow decisions 1–2.
6. **Every route is audited** against the owner, with the API key that called
   it, outside any transaction, like every other sandbox mutation.
7. **Revocation is the end of the work, not an option.** When Ravix's last
   direct Sprites call is gone, its token is deleted at Fly, its
   `SPRITES_TOKEN` is removed from Render and Infisical, and 0005 gains an
   addendum recording that no app holds a provider credential.

## Consequences

- One org-wide credential again, held by the platform only, as 0005 says.
- An app reaches a sandbox only as its owner, and every action is in the
  owner's audit trail.
- Wakes go through one path, so the waits measured in ravix-hq/ravix#496 and
  the state disagreement both stop.
- Preview traffic passes through Fountain's nodes instead of going from Ravix
  straight to Fly. That adds a hop and bandwidth on the home-cloud cluster
  (open question 1).
- Ravix must be rewritten against these routes, in stages, one use at a time.
  Its token stays valid until the last stage lands.
- Two new library capabilities to maintain across four providers.

## Alternatives considered

- **A separate Sprites organization for Ravix's account.** This bounds what
  Ravix's token reaches to Ravix's own machines, with almost no Ravix change.
  It still leaves an app holding a provider credential, unaudited by
  Fountain, waking machines outside the lease, and tied to Sprites. Kept as a
  possible interim step (open question 3).
- **Scoped provider tokens.** Not offered by Sprites (see Context).
- **Rotate, record the exception, and alert on Sprites API calls that don't
  come from Fountain.** Containment, not a fix.
- **Accept the exception because Ravix is our own product.** Ravix runs on
  separate hosting with its own access, so compromising Ravix would reach
  every Fountain tenant's machine.

## Open questions

1. **Where preview traffic flows.** Should tunnels go through Fountain's
   nodes? The alternative is Fountain minting a short-lived, single-port
   credential that Ravix presents to Fly, which Sprites does not appear to
   offer today.
2. **Order of work.** Recommended: commands first (they remove the wake
   problem), then terminals, then the library work for processes and
   tunnels.
3. **Interim containment.** While the routes are built, should Ravix's
   account move to its own Sprites organization, or should its current token
   be rotated?
4. **Command output and time limits.** What caps should `POST …/exec` have on
   output size and timeout? Ravix's longest exec today is its preview
   install.
