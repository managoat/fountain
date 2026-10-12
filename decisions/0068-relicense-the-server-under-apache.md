---
type: ADR
title: "Relicense the server under Apache-2.0"
description: "With Fountain no longer sold as a hosted service, the server (apps/fountain, the first-party extensions, config, priv) moves from AGPL-3.0-or-later to Apache-2.0, the licence the clients already carry. Supersedes 0027. Proposed: not in effect until every outside contributor to the AGPL paths has consented."
tags: [licensing, community]
status: draft
adr: "0068"
adr_status: "Proposed"
date: 2026-10-12
---

# 0068 — Relicense the server under Apache-2.0

**Status:** Proposed. The pull request that adds this ADR also replaces the
licence files and the documentation, but it stays a draft until every outside
contributor to the AGPL-licensed paths has agreed (see
[Consent](#consent-before-it-takes-effect)). Until it merges, 0027 governs.
On merge this ADR supersedes [0027](0027-agpl-relicensing.md).

## Context

[0027](0027-agpl-relicensing.md) chose AGPL-3.0-or-later for the server on the
eve of a commercial launch. Its reason was specific: a funded competitor could
take Fountain, host it, improve it and return nothing. AGPL section 13 answers
that one case. A modified server offered over a network owes its users the
source.

That reason no longer applies. Fountain is not sold as a hosted service any
more. It is a self-hosted application, and the billing, credits and growth
machinery that the hosted product needed is being removed. There is no hosted
product for a competitor to compete with, and no business whose improvements
need protecting from a private fork.

The AGPL still has costs. 0027 named them: some companies ban the AGPL by
policy, and those self-hosters were lost on purpose. For a self-hosted tool,
those people are now the audience. The split licence also needs explaining in
the README, `NOTICE`, `CONTRIBUTING.md`, the manual and every extension's
`mix.exs`. With one licence, that explanation is not needed.

`ee/` (Elastic License 2.0) holds the billing code. A separate pull request
deletes it. This ADR does not change `ee/`'s licence. While `ee/` remains in
the tree, its rows in `NOTICE`, the README and `CONTRIBUTING.md` stay as they
are. When `ee/` is deleted, those rows go with it.

## Decision

**The server is licensed under the Apache License 2.0.** That covers
`apps/fountain`, the first-party extensions (`apps/fountain_buzz`,
`apps/fountain_google`, `apps/fountain_microsoft`, `apps/fountain_slack`,
`apps/fountain_support`), `config` and `priv`. Each of those `LICENSE` files
holds the same Apache-2.0 text that `cli/` and `sdk/` already carry. The
clients do not change.

The terms for contributions stay as they are. Contributions come in under
Apache-2.0, and with this decision they also go out under Apache-2.0
(inbound=outbound). The DCO sign-off stays. The asymmetry stated in
`CONTRIBUTING.md` is gone, because there is no other outbound licence left to
relicense to.

### Consent before it takes effect

Outside contributors have merged code into the AGPL paths since 0027. The
inbound Apache-2.0 term of 0027's addendum (2026-08-22) already allows
Fountain to distribute their work under Apache-2.0. Every one of those
contributions merged after that date. Nobody agreed to the AGPL as the terms
their work would ship under, and this change makes those terms more
permissive, not less. Fountain asks each of them anyway. The pull request
lists them and stays a draft until each one agrees or their contribution is
rewritten. This ADR moves to Accepted when the pull request merges.

## Consequences

- **Releases before this change stay under the AGPL** (and those through
  v0.12.0 under MIT). Anyone who has one keeps those terms. `NOTICE` records
  the history.
- **Anyone can run, change and host the server without publishing their
  changes.** The protection 0027 wanted is given up on purpose. Without a
  hosted business, it protects nothing.
- **A hosted-only feature does not need `ee/` any more.** 0027's rule that an
  exclusive feature lives in `ee/` or gets published lapses. `ee/` is being
  deleted in any case.
- **The repository has one licence for all first-party code**, except `ee/`
  until it is deleted. Apache-2.0 requires that redistributors keep the
  licence and `NOTICE`. It adds no other obligation.
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
- **Relicense without asking contributors.** The inbound Apache-2.0 grant
  probably allows it, but asking is cheap, and it avoids any doubt about a
  contribution that came in while the project said its outbound licence was
  AGPL.
