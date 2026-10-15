---
type: ADR
title: "A Managoat instance and local control planes have different responsibilities"
description: "goatherd is an external consumer that vendors copies of the libraries Managoat folded back; Managoat owns service coordination, unattended lifecycle and callbacks."
tags: [architecture, libraries, product, hosting]
status: stable
adr: "0055"
adr_status: "Accepted"
date: 2026-09-14
generated: { by: openai/gpt-6, at: 2026-09-14T09:23:33Z }
verified: { by: openai/gpt-6, at: 2026-09-14T09:23:33Z }
stale_after: 2026-11-01
---

# 0055 — A Managoat instance and local control planes have different responsibilities

**Status:** Accepted, 2026-09-14, per the
[#1516 decision](https://github.com/managoat/fountain/issues/1516#issuecomment-5660991946).
It records an existing architectural boundary and commissions no new code.
goatherd was checked at
[`20d0e5c`](https://github.com/managoat/goatherd/tree/20d0e5cf15f4d51a964c8dd2118df569870a9a37),
Managoat's conversation supervision, callback keys and web routes at
[`67d65b46`](https://github.com/managoat/fountain/tree/67d65b46).

## Context

[goatherd](https://github.com/managoat/goatherd) is an Elixir escript that
provisions remote compute, installs a runtime's ACP adapter and drives a turn
that it renders in the terminal. It has no server, Managoat account, web UI or
database of its own; the user still supplies Sprites access and inference
credentials. It was built on three libraries extracted from Managoat
([0037](0037-component-libraries.md)): `managoat_sandbox`, `managoat_runtimes`
and `managoat_acp`. Those have since been folded back into
`apps/fountain/lib/managoat/`, their repositories archived and hex releases
retired; goatherd vendors copies under the same `Managoat.*` module names
([managoat/goatherd#1](https://github.com/managoat/goatherd/pull/1)). The two
share code by copying, not by a dependency.

The same sandbox and protocol can serve a human watching a turn locally or a
deployed service coordinating work. Every Managoat instance is self-hosted;
"instance" here means Managoat running as a service, not a hosted product.

## Decision

goatherd stays an independent application. A Managoat instance owns the
service responsibilities beyond a local driver watching a turn:

1. **More than one human.** Shared transcripts and work another person can
   open need service identity, authorization and coordination. goatherd's
   local transcript is not that contract. Org/team features are not planned.
2. **A closed laptop.** The remote adapter can keep running when the local
   driver disconnects, and `goatherd attach` can rejoin it, but that keeps no
   consumer of output or permission responder alive. With goatherd's
   interactive driver running, an unanswered permission request can wait
   indefinitely: the driver blocks on terminal input and installs no
   permission timer, and its locked
   [ACP peer (0.1.2)](https://github.com/managoat/managoat_acp/blob/v0.1.2/lib/managoat/acp/peer.ex#L663-L686)
   leaves timeouts to its owner. Managoat's `ConversationServer` owns the
   supervised lifecycle, output persistence and permission handling
   independently of an attached client;
   [`Conversations.Pending`](https://github.com/managoat/fountain/blob/67d65b46/apps/fountain/lib/fountain/conversations/pending.ex)
   denies unanswered requests on a timer.
3. **Triggers.** Work that starts when nobody typed needs a running service to
   admit it. That belongs on the service side, but Managoat runs no
   user-defined schedules: an application that wants a routine runs its own
   scheduler and prompts a conversation. goatherd gets no scheduler either.
4. **The broker and calls home.** Credential brokerage and the `managoat`
   fan-out skill's calls home need reachable service endpoints. Managoat's
   [`CallbackKey`](https://github.com/managoat/fountain/blob/67d65b46/apps/fountain/lib/fountain/conversations/callback_key.ex)
   supplies the base URL and token when sandbox API access is enabled;
   `sandbox_api_access: "none"` mints no key. Brokerage has its own endpoint
   and authorization. A laptop driver has no stable URL a sprite can call, so
   goatherd omits these integrations rather than reproducing a control plane
   through a tunnel or local callback server.

Sprites remains the compute provider either way: goatherd changes who runs the
control plane, not where files, checkouts and tools execute.

goatherd is not Managoat's onboarding path. The original issue's framing, a
signup-free on-ramp toward a 100-WAU goal, is not adopted, and the goal itself
is withdrawn. [#1579](https://github.com/managoat/fountain/issues/1579)
separately keeps the Postgres on-ramp in [0004](0004-postgres-day-one.md);
goatherd does not create a database-free edition.

## What the implementation establishes

Porting `Fountain.Conversations` into goatherd was unnecessary. Sandbox
filesystem durability and detachable adapter sessions let the local driver
reconnect without Managoat's tenant model or web lifecycle: goatherd uses
detachable `Sandbox.spawn`, rebuilds a handle from the recorded provider and
sandbox, and calls `Sandbox.attach`; it does not call `Sandbox.suspend`.

Its persistent state is not the four-field pointer file the issue described.
At the checked revision
[`Goatherd.State`](https://github.com/managoat/goatherd/blob/20d0e5cf15f4d51a964c8dd2118df569870a9a37/lib/goatherd/state.ex)
writes a JSON map of runs to `state.json`,
[`Goatherd.Runs.Run`](https://github.com/managoat/goatherd/blob/20d0e5cf15f4d51a964c8dd2118df569870a9a37/lib/goatherd/runs.ex)
has 13 fields, and the
[`driver`](https://github.com/managoat/goatherd/blob/20d0e5cf15f4d51a964c8dd2118df569870a9a37/lib/goatherd/driver.ex)
appends local NDJSON transcripts. The supported claim is smaller: remote
sandbox state plus local run metadata is enough to reconnect without a
database. Sandbox durability does not guarantee a complete local transcript
across driver downtime.

## Consequences

- goatherd is an external application that reuses the libraries' code, by
  copy since the fold-back. The earlier `managoat_examples` consumer stays
  recorded; goatherd is not retroactively the first external consumer.
- Managoat keeps the tenant, persistence, audit and service lifecycle
  contracts goatherd does not need. Their absence from goatherd is evidence
  about reuse, not grounds to remove them from the server.
- A second repository with its own README is not a second project site
  ([0034](0034-project-site-is-the-product-site.md)); goatherd documents
  itself in its own repository.
- There is no demo build or adoption commitment to track. Changes to the
  on-ramp need 0004's evidence-based revisit; changes to the local/service
  boundary need a new decision.

## Alternatives considered

- **Position goatherd as Managoat's signup-free demo or adoption funnel.**
  Rejected on 2026-09-14: it runs independently and does not change #1579's
  answer.
- **Port `Fountain.Conversations` into goatherd.** Unnecessary for watched
  turns and reconnecting; it would import the service's persistence and tenant
  responsibilities into a local application.
- **Make the local driver own service callbacks and unattended lifecycle.**
  That turns it into a deployed service with the reachability and lifecycle
  obligations Managoat already owns.
- **Another project site for goatherd.** A README for an independent
  application needs no second publisher for the manual.

## History

- 2026-09-14 — Accepted: goatherd consumes the libraries independently; the service owns multi-human, unattended, trigger and callback responsibilities (#1516).
- 2026-10-12 — Managoat is no longer sold as a hosted service; the 100-WAU goal that gated org/team work is withdrawn, and org/team features are not planned.
- 2026-10-15 — The team, its schedules and team MCP callbacks are removed ([0074](0074-remove-the-team.md)); Managoat runs no user-defined triggers.
- 2026-10-15 — The libraries are folded back into the server ([0037](0037-component-libraries.md)); goatherd vendors copies, and the title drops "share libraries" and "hosted".
