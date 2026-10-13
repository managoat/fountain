---
type: ADR
title: "Relicense the server under Apache-2.0"
description: "With Fountain no longer sold as a hosted service, the server (apps/fountain, config, priv) moves from AGPL-3.0-or-later to Apache-2.0, the licence the clients already carry. Supersedes 0027. Outside contributions came in under Apache-2.0, which covers the move, so it does not wait on fresh consent."
tags: [licensing, community]
status: stable
adr: "0068"
adr_status: "Accepted"
date: 2026-10-12
---

# 0068 — Relicense the server under Apache-2.0

**Status:** Accepted. Supersedes [0027](0027-agpl-relicensing.md).

## Context

[0027](0027-agpl-relicensing.md) chose AGPL-3.0-or-later for the server on the
eve of a commercial launch. Its reason was specific: a funded competitor could
take Fountain, host it, improve it and return nothing. AGPL section 13 answers
that one case. A modified server offered over a network owes its users the
source.

That reason no longer applies. Fountain is not sold as a hosted service any
more. It is a self-hosted application, and the billing, credits and growth
machinery that the hosted product needed has been removed, `ee/` (Elastic
License 2.0) with it (#2609). There is no hosted product for a competitor to
compete with, and no business whose improvements need protecting from a
private fork.

The AGPL still has costs. 0027 named them: some companies ban the AGPL by
policy, and those self-hosters were lost on purpose. For a self-hosted tool,
those people are now the audience. The split licence also needs explaining in
the README, `NOTICE`, `CONTRIBUTING.md` and the manual. With one licence, that
explanation is not needed.

## Decision

**The server is licensed under the Apache License 2.0.** That covers
`apps/fountain`, `config` and `priv`. The root `LICENSE` holds the same
Apache-2.0 text that `cli/` and `sdk/` already carry. The clients do not
change. The first-party extensions that 0027 also covered were deleted before
this change (#2606, #2614, #2617), so there is nothing else to relicense.

The terms for contributions stay as they are. Contributions come in under
Apache-2.0, and with this decision they also go out under Apache-2.0
(inbound=outbound). The DCO sign-off stays. The asymmetry stated in
`CONTRIBUTING.md` is gone, because there is no other outbound licence left to
relicense to.

### Outside contributions

Outside contributors have merged code into the AGPL paths since 0027. Every
one of those contributions merged after 0027's addendum (2026-08-22) took
contributions in under Apache-2.0, and `CONTRIBUTING.md` stated that term,
and the maintainer's right to relicense, the whole time. Apache-2.0 is the
licence this change distributes under, so the inbound grant covers it
directly. It makes the terms their work ships under more permissive, not less.

The relicense therefore does not wait on fresh consent. The contributors are
told about it on the pull request. Anyone who objects can say so, and their
contribution is rewritten rather than the change reverted.

## Consequences

- **Releases before this change stay under the AGPL** (and those through
  v0.12.0 under MIT). Anyone who has one keeps those terms. `NOTICE` records
  the history.
- **Anyone can run, change and host the server without publishing their
  changes.** The protection 0027 wanted is given up on purpose. Without a
  hosted business, it protects nothing.
- **The repository has one licence for all first-party code.** Apache-2.0
  requires that redistributors keep the licence and `NOTICE`. It adds no
  other obligation.
- **Dependencies are still compatible.** `open_api_spex` (MPL-2.0, unmodified)
  can be combined with Apache-2.0 code. `muzak` (CC-BY-NC-ND) is still
  `only: :test` and is not in the release image.
- **The Homebrew formula's licence field is corrected.** `release.yml` wrote
  `license "MIT"` for the CLI, which has been Apache-2.0 since 0027.

## Alternatives considered

- **Keep the AGPL.** It costs nothing to keep, but the companies that ban it
  are the self-hosters Fountain now wants, and it protects no business.
- **MIT.** Equally permissive, but it has no patent grant and would differ
  from the clients. Apache-2.0 matches `cli/` and `sdk/` and is already the
  inbound licence.
- **Wait for every outside contributor's consent.** It removes the last
  doubt about contributions that came in while the project said its outbound
  licence was AGPL, but the inbound grant already covers this, and several
  of those contributors may never answer. Notifying them, and rewriting any
  contribution whose author objects, gets the same result without blocking
  on silence.
