---
type: ADR
title: "The repo moves to the managoat organization, and every coordinate that names its owner moves with it"
description: "The repository moved from BinaryBourbon/fountain to the managoat organization on 2026-09-10, with every owner-scoped coordinate."
tags: [infra, open-source, release, deploy]
status: stable
adr: "0048"
adr_status: "Accepted"
date: 2026-09-10
generated: { by: human:jhgaylor, at: 2026-09-10T07:18:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-09-10T07:18:00-04:00 }
---

# 0048 — The repo moves to the managoat organization, and every coordinate that names its owner moves with it

**Status:** Accepted, 2026-09-10, and done that day. The repository and its
names were then renamed by [0082](0082-the-project-is-managoat.md); the
owner-scoped rules here still hold.

## Context

By September 2026 everything else lived in the `managoat` organization: the
hosted product presented as Managoat on `managoat.com` (#1177,
[0034](0034-project-site-is-the-product-site.md)), nine component libraries
had graduated to `managoat/managoat_*` on hex
([0037](0037-component-libraries.md), #1345), and the demos, templates and
tools were in the org. The server repo sat under `BinaryBourbon`, a GitHub
user account, not an organization. That cost three things:

- **No org primitives.** A user repo cannot carry org-level secrets, teams,
  org rulesets or a second admin. The ruleset's bypass was one person, and
  the repository secrets hung off an account that also held 19 unrelated
  repositories.
- **Every published coordinate said `binarybourbon`**: the container image,
  the Flux manifest artifact, the Go module paths, the Homebrew tap, the SDK
  manifests' repository URLs, and 286 references across 126 files.
- **A personal account was the project's home** while the libraries
  extracted out of it lived in an org.

The move itself is cheap: GitHub redirects git, the web UI and the REST API
permanently after a transfer, so clones, worktrees and every
`BinaryBourbon/fountain#NNNN` reference keep resolving, and issues, pull
requests, stars, webhooks, collaborators and the ruleset come along. What
does not come along is anything that names the owner in a registry, a module
path or a publisher's trust configuration. That is the content of this
decision.

## Decision

1. **The repository lives in the `managoat` organization**, transferred from
   `BinaryBourbon/fountain`, with the Homebrew tap (`managoat/homebrew-tap`).

2. **Every coordinate the project publishes is owner-`managoat`.** A package
   namespace belongs to its owner, and a repo's `GITHUB_TOKEN` can write
   packages only in its own owner's namespace, so the image, the Flux
   manifest artifact, the Go module path, the tap and the SDK manifests'
   repository URLs moved in the same window as the transfer. The image and
   artifact literals in `build.yml` and `publish-manifests.yml` are not
   derived from `github.repository`, so a build after an owner change fails
   loudly instead of publishing somewhere nobody watches. The Go module path
   is renamed rather than left naming the old owner; the module proxy keeps
   serving the old path's existing versions. Registry names that carry no
   owner (npm, hex) move on their own schedule, with both names published
   during a deprecation window, because a package rename breaks every
   consumer's `import` and a repository transfer breaks none.

3. **No new `binarybourbon` or `agentshit` coordinate.** Work writes the
   target coordinate, not the old one.

4. **Old GHCR packages are frozen, not deleted.** They stay public and
   readable, so anything pinned to an old tag or digest keeps pulling;
   nothing writes to them, and nothing is created at an old repository name
   that would break its redirect. Released tags are copied into the new
   namespace with `docker buildx imagetools create`, which keeps the
   multi-platform index; `latest` is not copied, because `build.yml` already
   points it at the newest main image. The copy goes after the repository's
   first build: a GHCR package grants push to the repository that created it,
   so a package seeded by a user's token is one `build.yml` cannot write.

5. **The moved coordinates are tested.** `release_pin_test.exs` and the CLI
   and SDK suites assert the published strings, so a sweep that misses a
   file fails CI rather than shipping a dead URL.

## Consequences

- **Some things broke, accepted.** `go install` on the old module path
  stopped working once `go.mod` declared the new one. GitHub Pages does not
  follow a transfer redirect, so `binarybourbon.github.io/fountain/` and the
  tombstone redirecting retired doc URLs (#1011) went dark; re-publishing it
  under the org does not bring the old URLs back. Self-host instructions
  pinned to the old image path keep working but drift until upgraded.
- **The cutover needed a merge freeze** of about ninety minutes, and
  production never stopped serving: the old pods ran the old digest until
  Flux reconciled the new artifact.
- **What a transfer does not carry.** On the day, the secrets, variables,
  environments, the ruleset's id and its required checks all transferred
  intact, but three things did not:
  - `gitleaks-action` is licensed for organizations, so the required secret
    scan failed on every PR; #1798 replaced the wrapper with the pinned
    (MIT, unmetered) CLI. Anything that gates merges and wraps a third-party
    action is worth checking for a per-owner-type licence before a move.
  - The ruleset's implicit owner bypass became `[]`, so admin merges were
    refused; it was re-declared as `OrganizationAdmin / always`.
  - The previous owner dropped to the org's base permission (read). The
    `BinaryBourbon` account is also the estate-medic bot identity, so it was
    given write, kept non-admin so it cannot approve its own PR, through a
    `managoat/engineering` team.
- **The GitHub Project stays with the user account**
  (`users/BinaryBourbon/projects/1`); no transfer moves it.
- **Bus factor improves**: the repo can have a second admin without handing
  over a personal account.
- A cutover day is a bad day not to know CI's external dependencies:
  `builds.hex.pm` returned gateway errors through the window and needed
  re-runs.

## Alternatives considered

- **Rename the `BinaryBourbon` user account to `managoat`.** Impossible, since
  the org holds the login, and wrong anyway: it would drag 19 unrelated
  repositories and the account's own identity along.
- **Leave the repo and move only the packages.** GHCR writes are owner-scoped,
  so CI would need a cross-account PAT: more credential, same fallout, later.
- **A fresh repo in the org plus a push.** Loses the open issues, the PR
  history, the stars and every cross-reference in `decisions/`.
- **Move one coordinate at a time.** The owner-scoped set cannot be gradual:
  the transfer invalidates every GHCR write at once.
- **`managoat/managoat`, renaming the product with the repo.** Rejected on
  2026-09-10 because 0034's edition split kept the project named Fountain;
  adopted on 2026-10-15 by 0082 once there was no hosted product for the
  split to describe.

## History

- 2026-09-10 — Decided and done: `BinaryBourbon/fountain` transferred to
  `managoat/fountain`, the coordinate sweep landed (#1795), the image and
  manifest artifact published to `ghcr.io/managoat/*`, home-cloud#221
  repointed Flux, the released tags were copied, and PyPI's trusted publisher
  was updated by hand.
- 2026-10-15 — [0082](0082-the-project-is-managoat.md) renames the project
  Managoat: the repository becomes `managoat/managoat`, the image
  `ghcr.io/managoat/managoat`, the Go module `github.com/managoat/managoat/cli`
  and the SDK `@managoat/sdk`. The `:fountain` OTP application, the Elixir
  modules and the database names stay. The old image name is frozen, not
  deleted, under decision 4.
