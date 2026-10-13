---
type: ADR
title: "AGPL-3.0 for the server, Apache-2.0 for the clients, Elastic 2.0 for ee/"
description: "Fountain relicenses from MIT before the commercial launch: AGPL-3.0-or-later on apps/fountain so a hosted fork owes its changes back, Apache-2.0 on cli/ and sdk/ so integrators carry no obligation, Elastic License 2.0 on ee/. Contributions come in under Apache-2.0 and go out under the directory's license, with a DCO and no CLA document (same-day addendum; #997)."
tags: [licensing, ee, community]
status: deprecated
adr: "0027"
adr_status: "Superseded by 0068"
date: 2026-08-22
generated: { by: human:jhgaylor, at: 2026-08-22T22:30:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-22T22:30:00-04:00 }
---

# 0027 — AGPL-3.0 for the server, Apache-2.0 for the clients, Elastic 2.0 for `ee/`

**Status:** Superseded by [0068](0068-relicense-the-server-under-apache.md)
(2026-10-12): the server is Apache-2.0 now that Fountain is not sold as a
hosted service. See the addendum at the end. Everything below is history.
Accepted 2026-08-22. Everything described here is built in the PR that adds
this ADR. `LICENSE` is the AGPL text, `cli/LICENSE` and
`sdk/typescript/LICENSE` are Apache-2.0, `ee/LICENSE` is the Elastic License
2.0, and `NOTICE` and `CONTRIBUTING.md` exist. This ADR supersedes the closing
line of 0010's addendum, which reserved the license question ("everything
remains MIT until an explicit license decision says otherwise"). This is that
decision.

## Context

Fountain was MIT-licensed from the first public commit (2026-05-10) through
v0.12.0 (2026-08-17), and is about to launch commercially (0026 builds the
paid tiers). MIT permits a funded competitor to take the work, host it, improve
it, and return nothing. The improvements are the part that matters: not the
revenue, which competition is entitled to pursue, but the fact that everyone
else running Fountain gets no benefit from a well-resourced fork's work.

Three facts made this the cheapest possible moment to act, and all three
expire:

- **Two stars, zero forks, and no npm publish.** No downstream user is relying
  on the MIT grant. A relicense a year from now would be the rug-pull the
  community reads as betrayal; today it is a choice made before release.
- **The `ee/` boundary already exists.** 0010 moved billing and growth mail
  behind a directory line *specifically* to preserve this option, and its
  addendum narrowed the scope so a community instance never needs `ee/` for
  anything real.
- **The copyright is entirely one holder.** No third-party contribution has
  ever been merged. `lex00` filed six issues in 2026-07 and pushed work to
  `origin/issue-*` branches, but opened no pull request, none of those commits
  is an ancestor of `main`, and `git blame` finds zero surviving lines. The
  features landed through separate commits the following day. MIT grants
  sublicensing rights in any case, so no contributor's consent was required.

## Decision

**Three licenses, one per directory, chosen by what the code is for.**

| Directory | License | Reason |
|---|---|---|
| `apps/fountain`, `config`, `priv` | AGPL-3.0-or-later | Section 13 is the whole point: run a modified server as a network service, owe your users the source |
| `ee/` | Elastic License 2.0 | Source-available, free to self-host, no copyleft, no competing hosted service |
| `cli/`, `sdk/typescript` | Apache-2.0 | An integrator must never inherit an obligation from calling the API |

The first-party single-page apps (`fountain-conversations`, `fountain-team`)
are Apache-2.0 in their own repositories, for the same reason as the SDK.

**Inbound=outbound, with a DCO and no CLA.** A contribution is licensed under
whatever governs the directory it touches. There is no copyright assignment.

### Why AGPL and not FSL or BUSL

The grievance is that improvements do not come back, not that a competitor
exists. AGPL answers exactly that and nothing more: a competitor may host
Fountain commercially, in direct competition with the hosted product, provided
they do it in the open. A non-compete source-available license (FSL, BUSL,
Elastic on the core) would answer a different grievance, forfeit the
OSI-approved "open source" claim at the moment of launch, and cost adoption
the project cannot yet afford to lose.

### Why the clients stay permissive

An AGPL SDK is poison. It puts a copyleft obligation on every proprietary
application that links it, which is precisely the integration Fountain wants.
The split follows the shape the ecosystem already uses (an AGPL Grafana with
Apache plugin SDKs, an SSPL MongoDB with Apache drivers). The API boundary is
the license boundary.

### Why `ee/` is Elastic License 2.0 and not AGPL

Two reasons, and the second is the load-bearing one.

The first is the obvious one: `ee/` is the commercial surface, and ELv2's
first limitation forbids offering it to third parties as a hosted service.

The second is that **AGPL binds Fountain's maintainer too**. With AGPL
everywhere, every hosted-only feature ever written would have to be published.
`ee/` is the lane where that is not true. That is what 0010 was actually
preserving, and it is worth more than the billing code itself, which is 4,550
lines of Stripe integration nobody needs to steal.

ELv2 rather than a bespoke license because the single-image decision
(0010's addendum) makes the grant load-bearing. `ee/` compiles into the same
`:fountain` OTP app via `elixirc_paths`, core calls it directly, there is no
ee-less build, and `billing_live.ex` still hosts the account export and
deletion UI. Every self-hoster therefore *runs* `ee/` code. A license without
a free use grant would make all of them infringers. ELv2 grants use and
modification at no cost and restricts only redistribution as a service, which
is the shape this actually needs. It is also drafted by lawyers, which a
bespoke file would not be.

### Why no CLA

> **Superseded the same day by the addendum below (#997).** Contributions now
> come in under Apache-2.0. The reasoning here is kept because the objection it
> raises is real and the addendum answers it rather than dismissing it.

A CLA would let the maintainer sell commercial exceptions to a company that
wants Fountain without AGPL obligations, converting the feared competitor into
a customer. It is declined because the asymmetry ("you grant me rights I do
not grant you") is the standard reason contributors walk away from a young
project, and Fountain needs contributors more than it needs that lever.

The consequence is accepted openly and written into `CONTRIBUTING.md`: with no
CLA, the maintainer cannot relicense a contributor's work either. The AGPL
guarantee binds the maintainer exactly as hard as it binds anyone else.

This is the one part of this ADR held open on purpose. Sole copyright means the
option is intact right now, and it closes at the first merged outside pull
request rather than on a date. **#997** tracks the decision and names the
question that settles it, which is whether selling a commercial exception is
ever part of the plan. The lighter form worth knowing about is inbound
Apache-2.0 with outbound AGPL: one sentence, no document and no bot, and
contributors keep full reuse rights over their own work.

## Consequences

- **Releases through v0.12.0 stay MIT, irrevocably.** Anyone who obtained them
  keeps that grant. This is unavoidable and is why the timing mattered.
- **Some enterprises cannot run Fountain.** AGPL is banned by policy at Google
  and at a meaningful number of other companies. Those self-hosters are lost,
  knowingly.
- **A hosted-only feature must live in `ee/` or be published.** This is a real
  roadmap constraint, and it is the first question to ask of any feature meant
  to be exclusive to the hosted product.
- **The inbound question was settled before the deadline it carried.** See the
  addendum. #997 is closed.
- **The dual-licensing option is preserved rather than spent.** Sole copyright
  meant commercial exceptions could be sold without asking anyone, and that
  would have ended at the first merged outside pull request. The addendum keeps
  it open.
- **`NOTICE` records the MIT terms** the v0.12.0 and earlier releases were
  distributed under. That record is for the people holding those releases, not
  a condition Fountain must satisfy, since no third-party code is in the tree.
- **Per-file license headers were not added.** A root LICENSE, `NOTICE` and
  the README table are the record. Headers across 56,000 lines are noise, and
  the AGPL does not require them.
- **Dependencies were checked and none conflict.** The set is MIT, Apache,
  BSD and ISC, plus `open_api_spex` (MPL-2.0, file-level copyleft, compatible,
  unmodified) and `muzak` (CC-BY-NC-ND, `only: :test`, absent from the release
  image).

## Not done yet (deliberately)

- **A lawyer has not reviewed this.** The structure is conventional and the
  license texts are verbatim from their canonical sources, so nothing here is
  novel drafting. An hour of review before the commercial launch is still
  cheap insurance, and the `ee/` grant is the clause to review first.
- **Trademark policy.** The licenses cover copyright. Nothing yet governs use
  of the Fountain name by a fork, which is the other half of how projects
  defend themselves.
- **The core-only build and the dependency-inversion seams** from 0010 remain
  unbuilt. They are not required by this decision, because ELv2 grants
  self-hosters the right to run `ee/`.

## Addendum — 2026-08-22: contributions come in under Apache-2.0 (#997)

The body above declined a CLA and left the inbound question open, tracked in
#997 with a deadline expressed as an event: the first merged outside pull
request. That deadline was uncomfortable precisely because the event is one the
project is actively trying to cause. It is settled now, the same day, rather
than left to be remembered under time pressure.

**Contributions are licensed to Fountain under the Apache License 2.0,
whichever directory they touch. Fountain distributes them under the license
governing that directory.** There is still no CLA document, no signing
ceremony and no bot. The DCO sign-off stays, and now also records agreement to
the inbound terms.

### Why this and not a CLA

It does the same job. Apache-2.0 permits sublicensing, so it preserves exactly
the right a CLA exists to preserve: the ability to distribute a contribution
under the AGPL, under ELv2, or under a commercial license sold to a company
whose policy forbids the AGPL.

What it avoids is the ceremony, which is most of what contributors actually
resent. There is no document to read, nothing to sign before a first patch, and
no bot blocking a pull request until an account is linked. For a project whose
scarcest resource is a first outside contributor, the difference between "open
a pull request" and "sign this, then open a pull request" is the whole cost.

It is also better for the contributor than a CLA in one concrete way.
Apache-2.0 places no restriction on them, so they keep the full right to reuse
their own contribution anywhere, including in proprietary work of their own. A
copyright assignment would not leave them that.

### What this does not change

The asymmetry is real and identical to a CLA's: the maintainer can relicense a
contribution, a contributor cannot relicense anyone else's. `CONTRIBUTING.md`
states it in those words rather than burying it, and invites the objection on
the pull request. Anyone who does not want that trade should not have to
discover it after their work is merged.

It changes nothing for `cli/` and `sdk/typescript`, where inbound and outbound
are both Apache-2.0 already.

It also does not commit Fountain to selling commercial exceptions. It keeps the
option. The decision to exercise it would be its own ADR, and the argument
against it, that a project taking contributions under copyleft and selling them
under proprietary terms is trading on goodwill it did not pay for, is not
answered here.

### Consequence

The body's "Why no CLA" section argued that the asymmetry deters contributors
and that Fountain needs contributors more than the lever. That objection is not
withdrawn. This addendum bets that the ceremony, not the asymmetry, is what
actually deters people, and that stating the asymmetry plainly is a better
answer than pretending to a symmetry the project did not want to keep. If that
bet is wrong, the fix is to drop the inbound term and revert to
inbound=outbound, which costs nothing except the option itself.

## Addendum — 2026-10-12: superseded by 0068

Fountain is no longer sold as a hosted service. The AGPL was here to stop one
thing: a competing host improving Fountain in private. With no hosted product
to compete with, that reason is gone, and the policy bans that the AGPL
triggers now cost the self-hosters Fountain is built for.
[0068](0068-relicense-the-server-under-apache.md) relicenses `apps/fountain`,
`config` and `priv` under Apache-2.0, the licence `cli/` and `sdk/` already
use. The inbound Apache-2.0 term from the addendum above is what makes that
possible without a CLA or a fresh round of consent. `ee/` and the first-party
extensions were deleted before it (#2606, #2609, #2614, #2617). Releases made
under this ADR stay under the AGPL for anyone who has them. This ADR is kept
as the record of why the AGPL was chosen.
