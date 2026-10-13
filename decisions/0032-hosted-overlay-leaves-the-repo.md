---
type: ADR
title: "The hosted instance's overlay leaves the repo; the manifest artifact is only the baseline plus the image pin"
description: "The maintainer's cluster-specific manifests (CNPG, Infisical, Traefik, hostnames, backups, alerts, Erlang clustering) move from k8s/ to the private home-cloud repo, which applies them on top of the OCI manifest artifact with Flux patches and a sibling Kustomization. k8s/ then went entirely (addendum): the artifact pins the image in deploy/k8s's own `images:` block and FOUNTAIN_BUILD_SHA is baked into the image. Built. Addendum 2026-10-12: the hosted deployed.yml schedule is removed; publish-manifests.yml stays (2026-10-13), so every merge to main still publishes the artifact the maintainer's instance deploys from."
tags: [deploy, infra, open-source, flux]
status: stable
adr: "0032"
adr_status: "Accepted"
date: 2026-08-25
generated: { by: human:jhgaylor, at: 2026-08-25T03:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-25T03:00:00-04:00 }
---

# 0032 — The hosted instance's overlay leaves the repo; the manifest artifact is only the baseline plus the image pin

**Status:** Accepted, built in the PR that adds this file. Nothing described
here is unbuilt.

## Context

The repo has carried two Kubernetes trees since #264:

- `deploy/k8s/` — the portable baseline a self-hoster applies. Plain
  manifests, no operators, a release tag pinned by `release-bump.yml`, and
  the thing the docs point at.
- `k8s/` — a kustomize overlay of that baseline for *the maintainer's own
  cluster*: a CloudNativePG `Cluster`, its backup `ObjectStore` and
  `ScheduledBackup`, an `InfisicalSecret`, a Traefik `IngressRoute` and
  cert-manager `Certificate` for `fountain.inevitable.fyi`, a 561-line
  `PrometheusRule`, a `ServiceMonitor`, the Erlang clustering env, the
  finance panel's rate card, the CORS origin list and the OAuth client list
  of a dozen sibling apps, and the image pin `publish-manifests.yml` rewrites.

`publish-manifests.yml` staged both into an OCI artifact
(`ghcr.io/binarybourbon/fountain-manifests`, #304) that the home-cloud
cluster's Flux reconciles. That mechanism bought one invariant — Flux never
sees a manifest without the image built from its tree — and it is kept.

What it also did was put the business's infrastructure in the AGPL repo.
Not secrets (Infisical is Kubernetes-native auth; nothing in `k8s/` was a
credential), but the topology, hostnames, pricing inputs and per-app OAuth
redirect URIs of one commercial deployment sat beside the product, in every
contributor's checkout and in every CI diff filter (`build.yml` special-cases
`k8s|deploy` to *not* trigger builds — a symptom). #487 proposed moving it
out and never started. The trigger now is that the hosted instance may move
to another platform, and a `fly.toml` for one account has no portable
half at all: it would be 100% infra and 0% product.

## Decision

1. **`k8s/` in this repo is the image pin and nothing else.** It holds a
   kustomization that includes `../deploy/k8s` and one strategic-merge patch,
   `pin.yaml`, carrying the image tag and `FOUNTAIN_BUILD_SHA`.
   `publish-manifests.yml` rewrites those two values in the artifact and
   fails if either substitution does not land, exactly as before. The
   artifact is therefore *the product's deployable*: the baseline and the
   image built from that tree.

2. **Everything personal lives in home-cloud** (private, the Flux repo that
   already consumes the artifact), as `platform/fountain-site/`:
   - the resources the overlay added — CNPG, backups, Infisical, headless
     Service, ServiceMonitor, PrometheusRule, IngressRoute, Certificate,
     PDB, ServiceAccount — reconciled by a Flux Kustomization
     `fountain-site` from home-cloud's own source;
   - the four patches the overlay applied to the baseline (Deployment,
     Service, Namespace, and the `$patch: delete` of the generic ConfigMap)
     as inline `spec.patches` on the existing `fountain` Kustomization that
     reads the OCI artifact. chant embeds them from
     `platform/fountain-site/patches/*.yaml` at build time.
   - the team Grafana dashboards, still shipped in this repo under
     `deploy/grafana/`, reconciled by a third Kustomization
     `fountain-dashboards` from the same artifact at path `./deploy/grafana`.
     The artifact's own kustomization does not include them, because the
     baseline must not assume a Grafana sidecar.

3. **The Namespace stays owned by the artifact's Kustomization.** Moving it
   to `fountain-site` would drop it from the `fountain` inventory and hand
   Flux's prune a Namespace holding the database. `fountain-site` therefore
   does not depend on `fountain`, and `fountain` does not depend on
   `fountain-site`; on a from-scratch rebuild the two converge over a retry
   interval instead of deadlocking (`fountain` creates the namespace and
   its pods wait on secrets; `fountain-site` fails once on the missing
   namespace, retries, and supplies them). The Namespace patch also carries
   `kustomize.toolkit.fluxcd.io/prune: disabled`, which it should have had
   since #304.

4. **Deploy-on-merge is unchanged.** A merge to `main` still builds an image,
   publishes the artifact with that image pinned, and nudges Flux. A change
   to the overlay now deploys through a home-cloud commit, which Flux
   reconciles on its own interval. The two are independent, and they can be:
   the overlay only ever changed on its own cadence.

## Consequences

- A contributor never sees a hostname, a rate card or an OAuth client list.
  The OSS repo's deploy surface is `deploy/` (self-hosting) and the
  ten-line `k8s/` pin.
- The docs lose the "read `k8s/` for the HA wiring" pointer. The Erlang
  clustering env is now written out in
  `docs/guides/operate/kubernetes.md` instead, which is where it belonged.
- `publish-manifests.yml`'s validate job no longer exercises CNPG or
  Infisical schemas — home-cloud's own validation covers what home-cloud
  owns. `promtool` still checks the baseline `PrometheusRule`.
- A future platform (Fly, or anything else) for the hosted instance is a
  home-cloud (or successor private repo) concern from day one. If a Fly
  path becomes a *supported self-host* option, a scrubbed example goes in
  `deploy/fly/`, kept honest by the same boot check the release job runs.
- `.sops.yaml` is deleted: the file it existed for
  (`k8s/fountain-infisical-auth.enc.yaml`) stopped existing when the
  operator moved to Kubernetes-native auth, and nothing else in the repo is
  SOPS-encrypted.
- Rollback is still `flux tag artifact … --tag latest` for the product, and
  `git revert` in home-cloud for the overlay.
- The cutover is ordered: home-cloud merges first (its `fountain`
  Kustomization fails to build against the old artifact and stops applying;
  `fountain-site` takes ownership of the moved resources), then this repo.
  The CNPG `Cluster` and the Namespace carry
  `kustomize.toolkit.fluxcd.io/prune: disabled` through it and after.
  home-cloud's `platform/fountain-site/README.md` has the checklist.

## Addendum (2026-08-25): `k8s/` is gone too

Decision 1 left a ten-line pin layer behind. It existed for two values the
baseline could not hold without a patch, and both found a better home:

- **The image tag** is written into the staged `deploy/k8s/kustomization.yaml`'s
  existing `images:` block (`newTag: v0.12.0` → `newTag: sha-<commit>`),
  same verify-or-fail. The artifact is now `deploy/` as committed plus that
  one rewritten line; Flux's path is `./deploy/k8s`.
- **`FOUNTAIN_BUILD_SHA`** is baked into the image by `build.yml`
  (`BUILD_SHA`), as `release.yml` always did. The reason it was removed —
  an image built from tree T should not claim to be one commit — was
  already not honoured by the manifest pin, which wrote the *image's*
  commit, not the deployed one. Baking says the same thing with no patch.

`deploy/` is the only Kubernetes directory in the repo. The artifact is
generic: any Flux could consume it and track `main` the way the hosted
instance does (`docs/guides/operate/kubernetes.md`).

The cutover order reversed: this repo first (the artifact loses `./k8s`,
home-cloud's `fountain` goes `BuildFailed` and applies nothing), then
home-cloud flips its path. The other order would have built the current
artifact's `./deploy/k8s` with the *release* pin and rolled prod back.

## Addendum (2026-10-12): the hosted verification schedule goes; the artifact stays

Fountain is a self-hosted product now, not a hosted service, so this
repository stops running the hosted instance's scheduled checks.
`.github/workflows/deployed.yml` goes: its schedule and its
`deployed-staging` and `deployed-production` environments existed for the
hosted instance. `deployed/` stays as a tool an operator runs by hand against
their own URL.

`.github/workflows/publish-manifests.yml` stays (decided 2026-10-13). The
maintainer's instance deploys from the artifact it publishes
(`ghcr.io/managoat/fountain-manifests`, through home-cloud's
`OCIRepository` and the `fountain-artifact-receiver`), and removing it would
have frozen that instance on its last artifact with nothing to replace it.
Anyone else can consume the same artifact, or `deploy/k8s` from a release
tag.

## Alternatives considered

- **A separate `fountain-ops` repo.** Suggested by #487; it was never
  created, and home-cloud already is the Flux source for this cluster with
  the receiver, the secrets backend and the dependency graph in place. A
  third repo would hold a kustomization and nothing that makes it
  reconcile.
- **Kustomize remote base pinned to a sha in home-cloud.** Preserves the
  pairing but needs a commit into home-cloud per merge — the git machinery
  #304 removed. Flux's inline `patches` on the artifact Kustomization
  express the same overlay without it.
- **Leave it, add a `.fly/` beside it.** Doubles the surface of the
  problem.

## Links

- #264 (the baseline/overlay split), #304 (the OCI artifact), #487 (the
  proposal this implements), #1001 (`deploy/grafana`).
- home-cloud `platform/fountain-site/README.md` documents the receiving end.
