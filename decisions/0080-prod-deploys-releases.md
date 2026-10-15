---
type: ADR
title: "Prod deploys releases, not merges"
description: "Only a successful vX.Y.Z release moves the manifest artifact's `latest` tag that production reconciles; every main sha still gets an immutable artifact."
tags: [deploy, release, ci, flux]
status: stable
adr: "0080"
adr_status: "Accepted"
date: 2026-10-15
---

# 0080 — Prod deploys releases, not merges

**Status:** Accepted, 2026-10-15 (Jake). Built. **Amends:** [0032](0032-hosted-overlay-leaves-the-repo.md) decision 4
("Deploy-on-merge is unchanged"), and
[0078](0078-one-maintainer-process.md) item 5, whose `publish-manifests.yml`
no longer deploys every push to main.

## Context

Until this change every green commit on `main` deployed. CI passed,
`build.yml` built `ghcr.io/managoat/managoat:sha-<sha>`, and
`publish-manifests.yml` published `ghcr.io/managoat/managoat-manifests` as
`sha-<short>` and moved `latest`. home-cloud's `OCIRepository` reconciles
`latest`, so each move was a rollout.

A rollout is no longer free. Managoat runs as one node, replaced with the
`Recreate` strategy ([0072](0072-fountain-runs-as-one-node.md)): the old pod
stops before the new one is ready. That is about 30 seconds of 502s, and a
conversation that is provisioning when it happens is lost. In the week to
2026-10-15, 106 commits landed on `main`, which is roughly one outage per
merge.

Prod also ran builds no one else runs. Self-hosters pin a release
(`vX.Y.Z`, or the `vX.Y` line), so the maintainer's instance was the only
deployment exercising each intermediate sha and the only one not running what
was released.

[0078](0078-one-maintainer-process.md) made a release one dispatch of
`release-bump.yml`, which pushes the bump commit and its tag atomically, so
cutting one costs a single command.

## Decision

1. **`latest` moves only for a release.** When `release.yml` completes
   successfully for a `vX.Y.Z` tag push, `publish-manifests.yml` publishes
   `deploy/` exactly as committed at the tag as the artifact `vX.Y.Z` and
   tags it `latest`. Nothing is rewritten. `release-bump.yml` already set
   `deploy/k8s`'s pin to `vX.Y.Z` in the tagged commit, so prod runs the
   image self-hosters pull. The workflow refuses if the tree's pin is not the
   tag, or if the image is not published.
2. **The trigger is `release.yml` finishing, not the tag push.** By then the
   versioned image exists, has booted through the documented quick start, and
   the GitHub Release is published. That closes the manifest-versus-image race
   that `publish-manifests.yml` exists to prevent, without polling for the
   image. The cost is that a failure in a late, unrelated release job (the
   Homebrew tap, say) leaves prod on the previous release until the
   maintainer promotes by hand (item 4).
3. **Every main sha still gets an artifact.** The build-completion path and
   the `deploy/**` fast path keep publishing `sha-<short>`, pinning the image
   built from that sha (or its newest built ancestor for a manifest-only
   commit), and do not move `latest`. Publishing one is a minute of a
   runner. In return a hotfix or rollback is one tag move to a validated
   artifact, and the kubeconform and promtool validation still runs at the
   merge that introduced a bad manifest, not at the next release.
4. **A manual escape hatch.** `publish-manifests.yml`'s dispatch takes a `ref`
   (a commit or a `vX.Y.Z` tag) and a `promote` flag:
   `gh workflow run publish-manifests.yml -f ref=<sha|vX.Y.Z> -f promote=true`.
   A dispatch skips the guard that refuses to move `latest` backwards,
   because a person naming an older ref means a rollback. The automatic
   release path keeps that guard.
5. **Rollback** stays one command against the registry:
   `flux tag artifact oci://ghcr.io/managoat/managoat-manifests:v<previous> --tag latest`.
6. **A manifest-only change ships with the next release.** A `deploy/**`
   commit gets a `sha-` artifact and waits for a release like code. If it
   cannot wait, promote it through the dispatch, or cut a release.

home-cloud needs no change: its `OCIRepository` already tracks `latest` and
its patches set no image. A comment in its Deployment patch says the pin is
"rewritten per publish"; for a release artifact it is the committed pin.

## Consequences

- Prod restarts once per release instead of once per merge. Prod is a
  release, so the instance the maintainer uses is the one self-hosters get.
- Feedback is slower. A regression reaches prod at the next release, possibly
  batched with others, rather than right after the merge that caused it.
  Bisecting it means reading a release's merged PRs.
- Verification moves. "Check prod after a merge" becomes "check prod after a
  release". A change that needs a prod check (a migration, a provider
  integration) needs a release, or a dispatched promotion of its sha, before
  it can be checked.
- After a hotfix promotion, prod runs a sha that is not a release until the
  next release replaces it. The dispatch is the documented exception, not
  the path.
- The image `latest` tag on `ghcr.io/managoat/managoat` is unaffected: it is
  still pushed by `build.yml` for every built main sha, and no deployment
  should run it.

## Alternatives considered

- **Trigger on the `v*` tag push and wait for the image.** It deploys before
  the quick-start boot check and has to poll or sleep for an image a
  concurrent workflow is building. Waiting for `release.yml` to finish gives
  the same result without a wait loop.
- **Promote the bump commit's `sha-` image instead of `vX.Y.Z`.** Same tree,
  but a different build from the one released and boot-checked, and it races
  `build.yml` on the bump commit. Pinning `vX.Y.Z` makes prod run the
  released bytes.
- **Stop publishing per-sha artifacts.** It saves a minute of runner time per
  merge, but loses hotfix and rollback targets and moves manifest validation
  to release time.
- **Batch merges (keep deploy-on-merge).** It relies on discipline, and the
  restart cost is paid per merge regardless.
- **Two replicas with a rolling update.** [0072](0072-fountain-runs-as-one-node.md)
  chose one node on purpose.

## History

- 2026-10-15 — Decided and built: `latest` moves only when `release.yml` succeeds for a `vX.Y.Z` tag.
- 2026-10-15 — The image and the manifest artifact renamed to `ghcr.io/managoat/managoat` and `ghcr.io/managoat/managoat-manifests` ([0082](0082-the-project-is-managoat.md)); the old names are mirrored for a deprecation window (#2776).
