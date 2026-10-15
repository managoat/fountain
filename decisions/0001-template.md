---
type: ADR Template
title: "ADR template (copy this when writing a real ADR)"
description: "Copy this file to write a new ADR; it fixes the frontmatter, the section shape, and the rule that unbuilt behavior is never described as built."
tags: [meta, template]
status: stable
adr: "0001"
adr_status: "Template"
generated: { by: human:jhgaylor, at: 2026-08-02T04:03:06-04:00 }
---

# 0001 — ADR template (copy this when writing a real ADR)

**Status:** Template — not a real decision. Copy this file as `decisions/NNNN-<short-title>.md` and fill it in.

## Frontmatter

Every ADR opens with an [OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
frontmatter block. `okf validate decisions` runs in CI and fails on a missing
`type`, a malformed date, or a link to an ADR that is not on this branch.
For a new ADR, use this frontmatter:

```yaml
---
type: ADR
title: "<title, without the NNNN prefix>"
description: "<one sentence: the decision as it stands now; name unbuilt behavior>"
tags: [<area>]
status: stable            # draft for Proposed; deprecated for Superseded, Retired, Rejected
adr: "NNNN"
adr_status: "Accepted"    # Proposed | Accepted | Partially accepted | Superseded by NNNN | Retired | Rejected
date: YYYY-MM-DD
---
```

`adr_status` records the decision; `status` is the corresponding OKF lifecycle
used by the validator. Proposed uses `draft`; Accepted and Partially accepted
use `stable`; Superseded by NNNN, Retired and Rejected use `deprecated`.
`scripts/decisions-index.sh` refuses any other pairing. Retired is an
Accepted decision that no longer holds; Rejected is a proposal that was never
accepted. A Superseded, Retired or Rejected ADR becomes a tombstone: its
frontmatter, a status line with the date, the reason and what replaced it,
and a link to its last full text at a fixed commit. The number and the file
stay so links keep working; git keeps the old text.

The body explains what is built and what remains unbuilt. Acceptance records a
decision, not proof that every described feature exists. Update that accounting
when implementation changes.

`generated`, `verified` and `stale_after` are optional historical metadata.
Routine edits do not require timestamps, verifier attribution or a review date.
If retained, a verification entry must describe an actual check; omit it rather
than asserting verification that did not happen. Git history records authors
and edits. Existing metadata can remain without being refreshed for prose edits.

`description` is the decision as it stands today, in one sentence; the index
is built from it. When the decision changes, rewrite the sentence rather than
appending "Amended …" to it: the history belongs in the body, and in git.

Run `scripts/decisions-index.sh` after changing the title, status or description,
or adding/removing an ADR; commit the resulting index. Run `okf validate decisions`
to check the bundle. No ADR is needed for routine fixes or internal refactors
that preserve an existing decision.

## Context

What's the situation forcing a choice? What constraints make this non-obvious? Link to relevant briefs, prior ADRs, or external docs.

## Decision

What we're doing. One paragraph. Be specific enough that a specialist reading this six months from now can act on it without asking.

## Consequences

What changes as a result? What are we giving up? What second-order effects should we expect?

## Alternatives considered

- **<option A>** — <one line on why not>.
- **<option B>** — <one line on why not>.
