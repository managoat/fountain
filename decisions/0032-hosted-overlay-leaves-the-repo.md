---
type: ADR
title: "The hosted instance's overlay leaves the repo; the manifest artifact is only the baseline plus the image pin"
description: "The maintainer's cluster-specific manifests live in the private home-cloud repo, layered with Flux on the OCI manifest artifact this repo publishes."
tags: [deploy, infra, open-source, flux]
status: stable
adr: "0032"
adr_status: "Accepted"
date: 2026-08-25
generated: { by: human:jhgaylor, at: 2026-08-25T03:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-25T03:00:00-04:00 }
---

# 0032 — The hosted instance's overlay leaves the repo; the manifest artifact is only the baseline plus the image pin

**Status:** Accepted — 2026-08-25. Built.

## Context

The repo carried two Kubernetes trees since #264: `deploy/k8s/`, the portable
baseline a self-hoster applies (plain manifests, no operators, a release tag
pinned by `release-bump.yml`), and `k8s/`, a kustomize overlay of it for the
maintainer's own cluster: CloudNativePG and its backups, an
`InfisicalSecret`, Traefik and cert-manager resources for one hostname, a
large `PrometheusRule`, a `ServiceMonitor`, clustering env, a rate card, the
CORS origin list and the OAuth client list of a dozen sibling apps, and the
image pin.

`publish-manifests.yml` staged both into an OCI artifact (#304) that the
home-cloud cluster's Flux reconciles. That bought one invariant worth
keeping: Flux never sees a manifest without the image built from its tree.

It also put one deployment's infrastructure in the product repo. Nothing in
`k8s/` was a credential, but its topology, hostnames, pricing inputs and
per-app OAuth redirect URIs sat in every contributor's checkout and every CI
diff filter (`build.yml` special-cased `k8s|deploy` to not trigger builds).
#487 proposed moving it out and never started. The trigger was that the
maintainer's instance might move to another platform, where a `fly.toml` for
one account has no portable half at all.

## Decision

1. **`deploy/` is the only Kubernetes directory in the repo**, and the
   artifact (`ghcr.io/managoat/managoat-manifests`) is `deploy/` as
   committed plus one rewritten line: the image tag in
   `deploy/k8s/kustomization.yaml`'s `images:` block, which
   `publish-manifests.yml` rewrites and fails if the substitution does not
   land. Flux's path is `./deploy/k8s`. The build SHA is baked into the image
   (`BUILD_SHA`) rather than patched into the manifests. The artifact is
   generic: any Flux can consume it, or `deploy/k8s` from a release tag.

2. **Everything specific to the maintainer's instance lives in home-cloud**
   (private, the Flux repo that already consumes the artifact), as
   `platform/fountain-site/`:
   - the resources the overlay added (CNPG, backups, Infisical, headless
     Service, ServiceMonitor, PrometheusRule, IngressRoute, Certificate, PDB,
     ServiceAccount), reconciled by a Flux Kustomization `fountain-site` from
     home-cloud's own source;
   - the patches the overlay applied to the baseline (Deployment, Service,
     Namespace, and the `$patch: delete` of the generic ConfigMap), as inline
     `spec.patches` on the `fountain` Kustomization that reads the artifact;
   - the Grafana dashboards, still shipped here under `deploy/grafana/`,
     reconciled by a third Kustomization `fountain-dashboards` from the same
     artifact. The artifact's own kustomization does not include them,
     because the baseline must not assume a Grafana sidecar.

3. **The Namespace stays owned by the artifact's Kustomization.** Moving it to
   `fountain-site` would drop it from the `fountain` inventory and hand Flux's
   prune a Namespace holding the database. Neither Kustomization depends on
   the other; on a from-scratch rebuild they converge over a retry interval
   instead of deadlocking. The Namespace patch and the CNPG `Cluster` carry
   `kustomize.toolkit.fluxcd.io/prune: disabled`.

4. **Prod deploys releases** ([0080](0080-prod-deploys-releases.md)). A merge
   to `main` builds an image and publishes a `sha-<short>` artifact, but does
   not move `latest` or nudge Flux. `latest` moves when `release.yml`
   succeeds for a `vX.Y.Z` tag, to an artifact `vX.Y.Z` pinning the release
   image. A change to the overlay deploys through a home-cloud commit on its
   own cadence.

5. **`publish-manifests.yml` stays** although Managoat is self-hosted only:
   the maintainer's instance deploys from the artifact, and removing it would
   freeze that instance on its last artifact. The hosted instance's
   scheduled checks (`deployed.yml` and its environments) are gone.

## Consequences

- A contributor never sees a hostname, a rate card or an OAuth client list.
  The repo's deploy surface is `deploy/`.
- `publish-manifests.yml`'s validate job no longer exercises CNPG or
  Infisical schemas; home-cloud's validation covers what home-cloud owns.
  `promtool` still checks the baseline `PrometheusRule`.
- A future platform for the maintainer's instance is a home-cloud concern. If
  one becomes a supported self-host option, a scrubbed example goes under
  `deploy/`.
- `.sops.yaml` is deleted: the one file it existed for stopped existing when
  Infisical moved to Kubernetes-native auth.
- Rollback is `flux tag artifact … --tag latest`, usually to the previous
  release's artifact, and `git revert` in home-cloud for the overlay.
- home-cloud's `platform/fountain-site/README.md` documents the receiving end.

## Alternatives considered

- **A separate ops repo** — suggested by #487, never created. home-cloud
  already is the Flux source with the receiver, secrets backend and
  dependency graph in place; a third repo would hold a kustomization and
  nothing that makes it reconcile.
- **Kustomize remote base pinned to a SHA in home-cloud** — preserves the
  pairing but needs a home-cloud commit per merge, the git machinery #304
  removed. Flux's inline `patches` express the same overlay without it.
- **Keep the overlay, add a `.fly/` beside it** — doubles the problem.
- **A ten-line `k8s/` pin layer** (the first cut) — it held only the image tag
  and the build SHA, and both found a better home: the baseline's own
  `images:` block and the image itself.

## History

- 2026-08-25 — Decided and built: the overlay moves to home-cloud; `k8s/` kept as an image-pin layer (#264, #304, #487, #1001).
- 2026-08-25 — `k8s/` removed too: the tag is rewritten in `deploy/k8s`, the build SHA baked into the image.
- 2026-10-12 — Self-hosted only: the hosted verification schedule goes; `publish-manifests.yml` stays (decided 2026-10-13). The `deployed/` harness was removed later (#2630).
- 2026-10-15 — Prod deploys releases, not merges ([0080](0080-prod-deploys-releases.md)).
