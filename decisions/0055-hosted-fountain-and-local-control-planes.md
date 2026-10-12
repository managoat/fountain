---
type: ADR
title: "Hosted Fountain and local control planes share libraries, with different responsibilities"
description: "goatherd drives watched turns through the component libraries; Fountain owns service coordination, unattended lifecycle, triggers and reachable callbacks. This is a boundary record, not an adoption path. No new features are commissioned. Amended 2026-10-12: the 100-WAU gate is withdrawn with the hosted service, and org/team features are not planned."
tags: [architecture, libraries, product, hosting]
status: stable
adr: "0055"
adr_status: "Accepted"
date: 2026-09-14
generated: { by: openai/gpt-6, at: 2026-09-14T09:23:33Z }
verified: { by: openai/gpt-6, at: 2026-09-14T09:23:33Z }
stale_after: 2026-11-01
---

# 0055 — Hosted Fountain and local control planes share libraries, with different responsibilities

**Status:** Accepted — 2026-09-14, per the
[#1516 decision](https://github.com/managoat/fountain/issues/1516#issuecomment-5660991946).
This records an existing architectural boundary and commissions no new code.
The goatherd library composition, detachable turns and local persistence were
checked at [`20d0e5c`](https://github.com/managoat/goatherd/tree/20d0e5cf15f4d51a964c8dd2118df569870a9a37);
Fountain's conversation supervision, callback keys and web routes were checked
at [`67d65b46`](https://github.com/managoat/fountain/tree/67d65b46).
The capabilities below describe service responsibilities, not a claim that
every org/team feature is built. Amended 2026-10-12 (see the end): the
100-WAU traction gate this ADR deferred to is withdrawn, and org/team features
are not planned.

## Context

[ADR 0037](0037-component-libraries.md) extracted reusable libraries from
Fountain. [goatherd](https://github.com/managoat/goatherd) now combines three
of them into an Elixir escript: `managoat_sandbox` provisions remote compute,
`managoat_runtimes` installs the runtime's ACP adapter, and `managoat_acp`
drives a turn that goatherd renders in the terminal. It has no server,
Fountain account, web UI, billing layer or database of its own. The user
still supplies Sprites access and inference credentials; signup-free here
means no Fountain signup.

This makes the distinction between the libraries and the service concrete.
The same sandbox and protocol can support a human watching a turn locally
or a deployed service coordinating work. "Hosted" here includes an
operator's self-hosted Fountain deployment; these responsibilities are not
exclusive to the Managoat commercial instance.

## Decision

Keep goatherd as an independent application consuming the component
libraries. Fountain owns the service responsibilities beyond a local driver
watching a turn. The boundary has four parts:

1. **More than one human.** Shared transcripts, teammates with inboxes and
   phone numbers, and work another person can open need service identity,
   authorization and coordination. goatherd's local transcript is not that
   shared contract. This allocation does not lift the org/team scope gate.
2. **A closed laptop.** The remote adapter can keep running when the local
   driver disconnects, and `goatherd attach` can rejoin it. That does not
   keep a consumer of output or a human permission responder alive. With
   goatherd's interactive driver still running, an unanswered permission
   request can wait indefinitely: the driver blocks on terminal input and
   installs no permission timer. Its locked
   [ACP peer (0.1.2)](https://github.com/managoat/managoat_acp/blob/v0.1.2/lib/managoat/acp/peer.ex#L663-L686)
   leaves timeout enforcement to its owner. Losing the driver is not a
   promise of unattended completion.
   Fountain's `ConversationServer` owns the supervised lifecycle, output
   persistence and permission handling independently of an attached browser
   or CLI; its
   [`Conversations.Pending`](https://github.com/managoat/fountain/blob/67d65b46/apps/fountain/lib/fountain/conversations/pending.ex)
   implements the permission timer used to deny unanswered requests.
3. **Schedules and other triggers.** Work that starts when nobody typed
   needs a running service to admit and coordinate it. Those triggers belong
   to Fountain's service side; this ADR does not add a scheduler to goatherd
   or authorize new scheduling features in Fountain.
4. **The broker and calls home.** Credential brokerage, the tool bridge
   (#1202), the `fountain` fan-out skill and team MCP callbacks require
   reachable service endpoints. Fountain's
   [`CallbackKey`](https://github.com/managoat/fountain/blob/67d65b46/apps/fountain/lib/fountain/conversations/callback_key.ex)
   supplies `FOUNTAIN_BASE_URL` and `FOUNTAIN_TOKEN` when sandbox API access
   is enabled; `sandbox_api_access: "none"` deliberately mints no key.
   Brokerage has its own endpoint and authorization. An ordinary laptop
   driver supplies no stable service URL a sprite can call. goatherd omits
   these service integrations rather than reproducing a hosted control plane
   through a tunnel or local callback server.

Sprites remains the remote compute provider in either arrangement. goatherd
changes who runs the control plane, not where the agent's files, Git checkout
and tools execute. That clarifies why Fountain exists alongside a local
application without claiming that one must funnel users into the other.

**This is not Fountain's onboarding path.** The original issue's
"signup-free on-ramp to the 100-WAU path" framing is not adopted.
[#1579](https://github.com/managoat/fountain/issues/1579) separately accepts
the Postgres on-ramp, including demos, in
[ADR 0004](0004-postgres-day-one.md). goatherd does not answer that issue or
create a database-free Fountain edition.

## What the implementation establishes

The anticipated port of `Fountain.Conversations` was unnecessary. Sandbox
filesystem durability and detachable adapter sessions let the local driver
reconnect without copying Fountain's tenant model, billing or web lifecycle.
The library's `attach`/`suspend` boundary separates sandbox lifecycle from
Fountain's database; goatherd's checked implementation uses detachable
`Sandbox.spawn`, rebuilds a handle from the recorded provider and sandbox,
and calls `Sandbox.attach`. It does not call `Sandbox.suspend` itself.

The issue's description of the **entire persistent state as a four-field
pointer file is stale**. At the checked revision,
[`Goatherd.State`](https://github.com/managoat/goatherd/blob/20d0e5cf15f4d51a964c8dd2118df569870a9a37/lib/goatherd/state.ex)
writes a JSON map of runs to `state.json`;
[`Goatherd.Runs.Run`](https://github.com/managoat/goatherd/blob/20d0e5cf15f4d51a964c8dd2118df569870a9a37/lib/goatherd/runs.ex)
has 13 fields, including sandbox/provider, session and prompt IDs, observed
status and a transcript path. The
[`driver`](https://github.com/managoat/goatherd/blob/20d0e5cf15f4d51a964c8dd2118df569870a9a37/lib/goatherd/driver.ex)
also appends local NDJSON transcripts. The supported architectural claim is
smaller: remote sandbox state plus local run metadata is enough to reconnect
without a database or a port of `Conversations`. Sandbox durability does not
guarantee a complete local transcript across driver downtime.

## Consequences

- ADR 0037's reuse claim has an external application consumer. Its earlier
  `managoat_examples` consumer remains recorded; goatherd is not retroactively
  the first external consumer of any kind.
- Fountain retains the tenant, persistence, audit, billing and service
  lifecycle contracts that this local application does not need. Their
  absence from goatherd is evidence about reuse, not grounds to remove them
  from Fountain or rewrite the server.
- [ADR 0034](0034-project-site-is-the-product-site.md) stands. A second
  repository with its own README is not a second Fountain project site.
  `managoat/fountain` is Fountain's repository home; `managoat.com` and
  `/docs` carry the product site and manual. Marketing remains in
  `managoat/site` under 0034's existing amendment. goatherd documents its own
  application in its own repository.
- There is no demo build or adoption commitment to track from this ADR.
  Changes to the on-ramp require the evidence-based revisit in ADR 0004;
  changes to the local/service boundary require a new decision.

## Alternatives considered

- **Position goatherd as Fountain's signup-free demo or adoption funnel.**
  Rejected by the 2026-09-14 decision: it runs the libraries independently
  and does not change #1579's answer.
- **Port `Fountain.Conversations` into goatherd.** Unnecessary for watched
  turns and reconnecting to a durable sandbox; it would import the service's
  persistence and tenant responsibilities into a local application.
- **Make the local driver own service callbacks, team coordination and
  unattended lifecycle.** That expands it into a deployed service with the
  same reachability and lifecycle obligations Fountain already owns.
- **Create another Fountain project site for goatherd.** A README for an
  independent application needs no second publisher for Fountain's manual.

## Amendment — 2026-10-12: the 100-WAU gate is withdrawn

Fountain is no longer sold as a hosted service (2026-10-12). The goal of 100
weekly active users by November 2026, which `CLAUDE.md` held and this ADR
cited as the gate on org/team work, is withdrawn with it (ADR 0003 and 0007,
retired). `CLAUDE.md` now says Fountain is a self-hosted product with no
org/team or billing features planned.

The boundary above is unchanged: goatherd drives watched turns through the
libraries, and Fountain owns service coordination, unattended lifecycle,
triggers and reachable callbacks. Two sentences read differently. "This
allocation does not lift the org/team scope gate" in decision 1 now means
org/team features are not planned, not that they wait on traction. The
"100-WAU path" in the original issue's framing has no target to lead to;
goatherd still is not Fountain's onboarding path.

The title's "hosted Fountain" means a Fountain instance running as a service,
which is what a self-hosted deployment is. It does not mean a hosted product.
