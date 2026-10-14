---
type: ADR
title: "Self-hosted runners: a user's own machine as a sandbox provider"
description: "Superseded 2026-10-14 by 0071: the self-hosted runner and its backends are removed. Was: A `fountain runner` daemon on a machine the user owns (a Mac mini, a home server) dials out to Fountain and serves the `Fountain.Sandbox` contract for that user; sandboxes are directories, processes stay alive between turns, nothing bills by the minute. Trusted mode only — no VM isolation, no egress policy — and the daemon must be online for the sandbox to be reachable."
tags: [sandbox, architecture, self-hosting, cli]
status: deprecated
adr: "0022"
adr_status: "Superseded by 0071"
date: 2026-08-19
generated: { by: human:jhgaylor, at: 2026-08-19T04:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-19T04:00:00-04:00 }
stale_after: 2026-11-19
---

# 0022 — Self-hosted runners: a user's own machine as a sandbox provider

**Status:** Superseded 2026-10-14 by [0071](0071-hosted-sandbox-providers-only.md);
see the addendum at the end. The text above it is history. Was: Accepted — built in this PR: `Fountain.Runners` (the `runners`
table + connection registry), `Fountain.Sandbox.Runner` (the fourth adapter),
`GET /api/runners/ws` (the daemon's socket) and `fountain runner` (the Go
daemon). What is deliberately *not* built is listed under
[Consequences](#consequences) — read it before assuming a runner isolates
anything.

Extends [0018](0018-sandbox-provider-abstraction.md) with a provider whose
control plane is on the *user's* side of the network, and reaffirms
[0017](0017-suspend-idle-sandboxes.md)'s never-aged-out invariant with the
cheapest possible park.

## Context

Every provider Fountain has (Sprites, E2B, Daytona) is a hosted Linux
sandbox that Fountain's server dials *into* with a platform credential and
pays for by the minute. That is right for the SaaS story and wrong for three
things people actually own:

- **hardware Fountain cannot rent** — a Mac (Xcode, macOS-only toolchains,
  Apple-silicon local models), a GPU box, a machine on a LAN with things
  worth reaching (a home cluster, devices, printers);
- **state that should just stay** — the sandbox is the agent's memory
  (0017); on a machine that never shuts down there is nothing to park and
  nothing to pay for keeping it;
- **the self-host audience** — a Fountain instance plus one's own machines is
  a fully sovereign setup, and that is the audience the MIT core exists for.

0018 built the seam (`Fountain.Sandbox`, one behaviour + one facade + one
error taxonomy, pinned by a conformance suite) precisely so a fourth backend
is an adapter, not an architecture. The one thing 0018 did not anticipate is
a provider Fountain cannot dial: a Mac mini at home is behind NAT, so the
connection has to go the other way.

## Decision

### The runner dials out; Fountain routes RPCs to it

`fountain runner --name <name>` (in the existing Go CLI) authenticates with
the user's ordinary API key, opens a WebSocket to `GET /api/runners/ws`, and
holds it. The server side registers the connection process under
`{user_id, runner_id}` in a cluster-wide registry (`Fountain.Runners.Registry`
on Horde, like the conversation servers) and upserts a `runners` row
(`user_id`, `name`, `hostname`, `os`, `arch`, `version`, `last_seen_at`,
`connected_at`). A runner is *online* while a connection process is
registered for it. Nothing about the runner is a credential: the row is
identity and telemetry, and the API key is what authenticates each socket.

The adapter, `Fountain.Sandbox.Runner`, implements every `Fountain.Sandbox`
callback as a request over that socket (`Fountain.Runners.Connection.call/3`,
with a JSON frame protocol; streaming output arrives as pushed frames that the
connection process forwards to the command's owner as the standard
`{:stdout | :stderr | :exit, %{ref: ref}, _}` messages). The connection
process lives on whichever node accepted the socket; the owner may be on any
node — Erlang message passing carries the frames across.

### Which runner: encoded in the sandbox name

`Fountain.Sandbox` hands an adapter nothing but the sandbox *name* (0018:
`build_handle/1` is pure and handles are rebuilt from the row on every wake),
so the routing key has to be in the name. Runner sandboxes are minted as
`runner-<runner_id>-<short>` (`runner_id` is the row's UUID without dashes)
at the two mint sites in `Fountain.Conversations`, which pick the user's
runner at that moment. Per-agent pinning (`agents.runner_id`) is **not built**;
today the selection rule is *the user's most recently connected online
runner*, and minting fails with `{:error, :no_runner_online}` when there is
none. A
handle for a runner that is currently offline yields `{:unavailable,
:runner_offline}` from every operation — transient in the taxonomy, so the
wake path retries and never mistakes it for `:not_found` (a parked directory
on a machine that is switched off is still the agent's memory).

### What a sandbox is on a runner

A directory: `<root>/<name>` (default root `~/.fountain/runners/<name>/sandboxes`).
Every command runs with `HOME` set to that directory and cwd inside it, so
the provisioning pipeline's `/home/sprite/...` writes and `~`-relative
scripts land in the sandbox: **`/home/sprite` is mapped to the sandbox
directory** by the daemon, for `write_file` paths and for `HOME`. Everything
else — `PATH`, the toolchain, the agent CLIs — is the host's. There is no
`sprite` user; commands run as whoever started the daemon.

The contract maps as follows:

| Fountain operation | Runner mechanics |
|---|---|
| Name-keyed create/adopt | `mkdir -p`; an existing directory is adopted |
| `get` | directory present → `:running`; absent → `:not_found`; runner offline → `{:unavailable, :runner_offline}` |
| Suspend / resume | Advertised (`:suspend`): suspend terminates the sandbox's live processes and keeps the directory; resume is a no-op. Idle parking costs nothing, and the never-aged-out rule holds trivially |
| Exec | `exec.Command` to completion with env, cwd, timeout; nonzero exit is data |
| Streaming / reattach | The daemon journals every session's frames in memory and on disk under `<sandbox>/.fountain/sessions/<id>.log`; `attach` replays from byte zero then tails; the exit code is the real one. Detachable sessions outlive the socket — the whole point of a machine that stays up |
| Stdin | A pipe to the process; `close_stdin` is a real EOF; writes after exit are `{:error, :command_exited}` |
| `list_all_names` | The union over the user's runners that are online *now*, `{:ok, _}` even when that is empty. Offline runners' sandboxes are simply not in the view, which the reaper already treats as "skip, converge later" — it never destroys a row whose name is missing from the listing |
| Network policy | Not advertised. `apply_network_policy/2` returns `{:error, :not_supported}`; a `limited` environment fails to provision on a runner, on purpose |
| Checkpoints, public URL, TTY | Not advertised |

Enabledness: the provider needs no platform credential, so
`Fountain.Sandbox.enabled?(:runner)` is `SANDBOX_RUNNERS_ENABLED` (default
`true`), the one non-credential switch in `credential_present?/1`, and an
operator who does not want users' machines running agents turns it off.
`SANDBOX_PROVIDER=runner` as the instance default is allowed and needs no
credential either.

### Wire protocol

JSON text frames, one request/response pair per `id`, plus unsolicited
`stream` frames from the daemon:

```
→ {"id":1,"op":"create","name":"runner-…"}          ← {"id":1,"ok":true,"result":{}}
→ {"id":2,"op":"spawn","name":…,"cmd":…,"args":[…],"env":[[k,v]…],"dir":…,"stdin":true,"detachable":true}
                                                     ← {"id":2,"ok":true,"result":{"session_id":"s-…"}}
                                                     ← {"stream":"stdout","session_id":"s-…","data":"<base64>"}
                                                     ← {"stream":"exit","session_id":"s-…","code":0}
→ {"id":3,"op":"stdin","session_id":"s-…","data":"<base64>"}
→ {"id":4,"op":"stdin_close","session_id":"s-…"}
→ {"id":5,"op":"attach","session_id":"s-…"}          ← replays every frame, then tails
→ {"id":6,"op":"detach","session_id":"s-…"}          (stop_command: this node stops listening; the process lives)
```

Errors come back as `{"id":n,"ok":false,"error":"not_found" | "command_exited" | …}` and
map onto the taxonomy verbatim; anything else is `{:provider, :runner, detail}`.
The daemon speaks `hello` first (name, hostname, os, arch, version, root); the
server rejects a `hello` for a runner name that already has a live connection
(two daemons with one name would split a sandbox's sessions across them).

## Consequences

- A user gets a sandbox provider for the price of a `fountain runner` process;
  a self-hosted instance gets one that needs no vendor account at all.
- **Trusted mode is the only mode.** The daemon runs whatever the agent runs,
  as the daemon's user, on the user's machine, with the user's network. There
  is no VM, no container, no `sandbox-exec`, no egress policy — and the docs,
  the agent form and this ADR say so. A container/VM mode (Apple's
  `container`, Tart, a Linux runner under Docker) is compatible with the
  protocol (the daemon would translate `create` into a container and `HOME`
  into a mount) and is **not built**.
- The Agent Vault egress chokepoint of 0016 does not apply: a runner is behind
  the user's firewall, and vault values are injected as plain env like on any
  provider. Governance for runners means running the proxy on the runner
  host, which is not built.
- `apt` packages in an environment fail on a Mac runner (there is no apt);
  `npm` packages install into the host's global prefix. Neither is translated.
- Per-agent runner pinning (`agents.runner_id`), a runner picker in the agent
  form, runner-side resource limits and a systemd/launchd install helper are
  follow-ups; the shape (a runner row per machine, the id in the name) does
  not need to change for any of them.
- The reaper's listing for `:runner` reflects only online runners; a sandbox
  whose runner never comes back is a directory on a machine Fountain cannot
  see, which costs Fountain nothing and is the user's to delete.

## Addendum — 2026-10-14: superseded by 0071, the runner is removed

[0071](0071-hosted-sandbox-providers-only.md) removes the provider this ADR
built (#2676): `Fountain.Runners`, the runner adapter and its registry, the
`/api/runners` routes, the `/account/runners` page, `fountain runner`,
`SANDBOX_RUNNERS_ENABLED` and the `managoat_runner` dependency. A migration
moves agents pinned to `runner` to the instance default and marks live
runner sandboxes terminated; terminal rows keep `provider = 'runner'` as
history. The `runners` table is dropped one release later. Nothing above
describes the current system.
