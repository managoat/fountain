---
type: ADR
title: "Relicense the server under Apache-2.0"
description: "The server is Apache-2.0, like the clients."
tags: [licensing, community]
status: stable
adr: "0068"
adr_status: "Accepted"
date: 2026-10-12
---

# 0068 — Relicense the server under Apache-2.0

**Status:** Accepted, 2026-10-12. Supersedes [0027](0027-agpl-relicensing.md).

## Context

[0027](0027-agpl-relicensing.md) chose AGPL-3.0-or-later for the server on the
eve of a commercial launch. Its reason was specific: a funded competitor could
take the server, host it, improve it and return nothing. AGPL section 13
answers that one case. A modified server offered over a network owes its users
the source.

That reason no longer applies. Managoat is not sold as a hosted service. It is
a self-hosted application, and the billing, credits and growth machinery that
the hosted product needed has been removed, `ee/` (Elastic License 2.0) with
it (#2609). There is no hosted product for a competitor to compete with, and
no business whose improvements need protecting from a private fork.

The AGPL still has costs. 0027 named them: some companies ban the AGPL by
policy, and those self-hosters were lost on purpose. For a self-hosted tool,
those people are now the audience. The split licence also needed explaining in
the README, `NOTICE`, `CONTRIBUTING.md` and the manual.

## Decision

The server is licensed under the Apache License 2.0. That covers
`apps/fountain` (including `apps/fountain/priv`) and `config`. The root
`LICENSE` holds the same Apache-2.0 text that `cli/` and `sdk/` already carry.
The clients do not change. The first-party extensions that 0027 also covered
were deleted before this change (#2606, #2614, #2617), so there is nothing
else to relicense.

Contributions come in and go out under Apache-2.0, by section 5 of the
licence. There is no separate contributor agreement: the explicit inbound term
0027 added existed so a contribution could go out under a different licence
from the one it came in under, and there is no different licence left. There
is no DCO sign-off either ([0078](0078-one-maintainer-process.md)): with one
maintainer there is no outside contribution whose origin a trailer would
certify, and CI does not check for one.

### Outside contributions

Outside contributors merged code into the AGPL paths while 0027 held. Every
one of those contributions merged after 0027's addendum (2026-08-22) came in
under Apache-2.0, and `CONTRIBUTING.md` stated that term, and the maintainer's
right to relicense, the whole time. Apache-2.0 is the licence this change
distributes under, so the inbound grant covers it directly. It makes the terms
their work ships under more permissive, not less.

The relicense therefore did not wait on fresh consent. The contributors were
told on the pull request
([#2605](https://github.com/managoat/fountain/pull/2605), which names each of
them and their pull requests). Anyone who objects can say so, and their
contribution is rewritten rather than the change reverted.

## Consequences

- Releases before this change stay under the AGPL (and those through v0.12.0
  under MIT). Anyone who has one keeps those terms. `NOTICE` records the
  history.
- Anyone can run, change and host the server without publishing their
  changes. The protection 0027 wanted is given up on purpose. Without a hosted
  business, it protects nothing.
- The repository has one licence for all first-party code. Apache-2.0 requires
  that redistributors keep the licence and `NOTICE`. It adds no other
  obligation.
- Dependencies are still compatible. `open_api_spex` (MPL-2.0, unmodified) can
  be combined with Apache-2.0 code.
- The Homebrew formula's licence field is corrected. `release.yml` wrote
  `license "MIT"` for the CLI, which has been Apache-2.0 since 0027.

## Alternatives considered

- **Keep the AGPL.** It costs nothing to keep, but the companies that ban it
  are the self-hosters Managoat now wants, and it protects no business.
- **MIT.** Equally permissive, but it has no patent grant and would differ
  from the clients. Apache-2.0 matches `cli/` and `sdk/` and was already the
  inbound licence.
- **Wait for every outside contributor's consent.** It removes the last doubt
  about contributions that came in while the project said its outbound licence
  was AGPL, but the inbound grant already covers this, and several of those
  contributors may never answer. Notifying them, and rewriting any
  contribution whose author objects, gets the same result without blocking on
  silence.

## History

- 2026-10-12 — Server relicensed from AGPL-3.0-or-later to Apache-2.0; contributors notified on #2605.
- 2026-10-13 — Explicit inbound contributor term dropped from `CONTRIBUTING.md`; section 5 of the licence covers it. The DCO sign-off stayed.
- 2026-10-14 — `priv` clarified as `apps/fountain/priv`; `NOTICE` names the server as `apps/fountain` and `config`.
- 2026-10-15 — DCO sign-off dropped by [0078](0078-one-maintainer-process.md).
- 2026-10-17 — `muzak` is no longer a dependency, so the note that it was test-only is dropped.
