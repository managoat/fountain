---
type: ADR
title: "The repo moves to the managoat organization, and every coordinate that names its owner moves with it"
description: "Done on 2026-09-10: BinaryBourbon/fountain — a personal user account — transferred to managoat/fountain, keeping the repo name and the project name (0034). The owner-scoped coordinates moved with it: ghcr.io/managoat/fountain and ghcr.io/managoat/fountain-manifests, github.com/managoat/fountain/cli and the Buzz provider module beside it, managoat/homebrew-tap. Production reconciles the new artifact and serves the new image. The registry names that carry no owner (npm @agentshit, PyPI fountain-agent-sdk, hex fountain_sdk) are decided here and move separately. Nothing is outstanding: the v0.16.0 and v0.16 tags were copied to the new path and the quick-start boot check verified against them, and PyPI trusted publishing now names the new owner. Amended 2026-10-15 by 0082: the project is renamed Managoat, and the repository is to move to managoat/managoat, the alternative rejected here."
tags: [infra, open-source, release, deploy]
status: stable
adr: "0048"
adr_status: "Accepted"
date: 2026-09-10
generated: { by: human:jhgaylor, at: 2026-09-10T07:18:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-09-10T07:18:00-04:00 }
---

# 0048 — The repo moves to the managoat organization, and every coordinate that names its owner moves with it

**Status:** Accepted and **done on 2026-09-10**. The repo is
`managoat/fountain`, the sweep landed in #1795, the image and the manifest
artifact publish to `ghcr.io/managoat/*`, home-cloud#221 flipped the
`OCIRepository`, and production serves
`ghcr.io/managoat/fountain:sha-e6fd69e6…` with `/llms.txt` pointing readers at
`github.com/managoat/fountain`. What the cutover found, including three things
this file did not predict, is in *After the move* below.

**Amended 2026-10-15** by [0082](0082-the-project-is-managoat.md): the
project is renamed Managoat, so decision 1's "the project keeps its name" and
the rejected `managoat/managoat` alternative are reversed. See the amendment
at the end.

**Nothing is outstanding.** The two items this file listed as owed on the day
were both closed before the session ended:

- **The released tags exist at the new path.** `v0.16.0` and the moving `v0.16`
  were copied with `docker buildx imagetools create`, which preserves the
  two-platform index rather than flattening it; both carry the source digest
  `sha256:c94fb66d…`. `latest` was deliberately **not** copied — `build.yml`
  already points it at the newest main image, and overwriting it would move it
  backwards. `scripts/compose-boot-check.sh` then ran against the copy and
  answered `/health` and `/health/ready` with 200, so `ci.yml`'s quick-start job
  boots a real image again instead of taking its release-bump exemption.
- **PyPI's trusted publisher names the new owner.** Done by hand, web-only as
  expected.

## Context

Everything else has already moved. The hosted product presents as Managoat on
`managoat.com` (#1177, 0034). Nine component libraries graduated to
`managoat/managoat_*` on hex (0037, #1345). The demo suite, `goatherd`,
`airlock`, `manasprites`, `managoat_examples`, the three `fountain-template-*`
starters and `review-loop` are all in the org; `scripts/graduate-library.sh`
already rewrites a graduating library's `@source_url` to
`https://github.com/managoat/<app>` (line 147).

The server repo is the last piece, and it sits under `BinaryBourbon` — a
GitHub **user** account, not an organization. That has three costs:

- **No org primitives.** A user repo cannot carry org-level secrets, teams,
  org rulesets or a second admin. `Main Protection` is a repo ruleset whose
  bypass is one person, and the five repository secrets
  (`FLUX_WEBHOOK_URL`, `HEX_API_KEY`, `HOMEBREW_TAP_TOKEN`,
  `RELEASE_BUMP_TOKEN`, `RENDER_DEPLOY_HOOK_URL`) hang off an account that
  also holds 19 unrelated repositories.
- **Every published coordinate says `binarybourbon`.** The container image,
  the Flux manifest artifact, both Go module paths, the Homebrew tap, the four
  SDK manifests' repository URLs, and 286 references across 126 files in this
  tree. A reader who arrives from `managoat.com` or from
  `managoat/managoat_acp` finds a personal account.
- **0034's split reads wrong from outside.** 0034 decided the names split by
  edition: *Fountain* is the AGPL server, CLI and SDK; *Managoat* is one
  hosted instance; the project is not renamed. That split survives this move —
  the org is where the engineering lives (it already holds nine Fountain
  libraries), the repo name is what the project is called. What it does not
  survive is a personal account being the project's home while the libraries
  extracted *out of* that project live in an org.

The move itself is cheap: GitHub redirects git (clone, fetch, push), the web
UI and the REST API permanently after a transfer, so clones, the ~60 live
worktrees, and every `BinaryBourbon/fountain#1345` reference in commit prose
and in `decisions/` keep resolving. Issues (151 open), pull requests, stars,
forks, webhooks, collaborators and the ruleset come along.

What does not come along is anything that names the owner in a registry, a
module path or a publisher's trust configuration. That is the whole content of
this decision.

## Decision

### 1. `BinaryBourbon/fountain` transfers to `managoat/fountain`

The repo keeps its name. The project keeps its name (0034). `managoat/managoat`
and a Fountain-to-Managoat product rename are **not** this decision and are
rejected below.

### 2. Every coordinate we publish is owner-`managoat`, and its final name is fixed now

Two classes, because they behave differently on the day of the transfer.

**Forced by the transfer** — a package namespace belongs to its owner, and a
repo's `GITHUB_TOKEN` can only write packages in its own owner's namespace.
The moment the repo is under `managoat`, a push to `ghcr.io/binarybourbon/*`
fails with a 403. These move in the same window as the transfer:

| What | Before | After |
|---|---|---|
| Server image | `ghcr.io/binarybourbon/fountain` | `ghcr.io/managoat/fountain` |
| Flux manifest artifact | `ghcr.io/binarybourbon/fountain-manifests` | `ghcr.io/managoat/fountain-manifests` |
| CLI module | `github.com/BinaryBourbon/fountain/cli` | `github.com/managoat/fountain/cli` |
| Buzz provider module | `github.com/BinaryBourbon/fountain/apps/fountain_buzz/cli` | `github.com/managoat/fountain/apps/fountain_buzz/cli` |
| Homebrew tap | `BinaryBourbon/homebrew-tap`, `brew install BinaryBourbon/tap/fountain` | `managoat/homebrew-tap`, `brew install managoat/tap/fountain` |
| Repository URLs in the four SDK manifests | `github.com/BinaryBourbon/fountain` | `github.com/managoat/fountain` |

The image literal lives in `build.yml:35` (`IMAGE`) and the artifact in
`publish-manifests.yml:142` (`MANIFESTS`); neither is derived from
`github.repository`, which is why the first build after the transfer fails
loudly instead of publishing somewhere nobody watches. The published pins are
`docker-compose.yml:39`, `deploy/k8s/deployment.yaml:43`,
`deploy/k8s/kustomization.yaml:29`, `render.yaml:41` and `fly.toml:37`, and
`apps/fountain/test/fountain/release_pin_test.exs:16-19` asserts three of them
by regex — that test is the gate proving the sweep was complete, so it moves
with them rather than being relaxed.

The Go rename is two `go.mod` files plus the cross-module `require` and
`replace` (`apps/fountain_buzz/cli/go.mod:17,22,53`) and the one import
(`apps/fountain_buzz/cli/internal/backend/fountain.go:7`). We rename rather
than keep the old path declared, because the module path is also what
`docs/cli.md` tells a reader to `go install`, and a module path naming an
account that no longer hosts the code is worse than a break we document. The
module proxy keeps serving the old path's existing versions, so a pinned build
keeps building.

**Not forced by the transfer** — these registry names carry no owner, so
nothing breaks on the day. The direction is decided here; each moves in its
own PR, on its own schedule, with both names published during a deprecation
window:

| What | Now | Target |
|---|---|---|
| TypeScript SDK | `@agentshit/fountain-sdk` (npm) | `@managoat/fountain-sdk` |
| Python SDK | `fountain-agent-sdk` (PyPI) | a `managoat`-prefixed name |
| Elixir SDK | `fountain_sdk` (hex) | unchanged unless it collides; hex has no scopes |

An SDK package rename breaks every consumer's `import` — the three template
repos, `managoat/demos`, `fountain-conversations`, `fountain-team`, Workbench,
`salon` — so it is deliberately not coupled to a repository transfer that
breaks none of them.

### 3. No new `binarybourbon` or `agentshit` coordinate, starting now

Any work merged from this point writes the target coordinate, not the current
one. The 48 `@agentshit/fountain-sdk` references in `docs/`, `README.md` and
`CHANGELOG.md` stay until that rename lands (rewriting them before the package
exists would document something unpublishable), but nothing new joins them.

### 4. The old GHCR packages are frozen, not deleted

`ghcr.io/binarybourbon/fountain` and `-manifests` stay public and readable
after the cutover. Any cluster, compose file or `render.yaml` pinned to an old
tag or digest keeps pulling. We stop writing to them; we do not delete them,
and we do not delete the old repo name's redirect by creating anything at
`BinaryBourbon/fountain`.

The released tags are **copied** into the new namespace rather than left
behind. `ci.yml`'s quick-start job fails when `.env.compose.example`'s pin has
no image, with one exemption — a pin equal to `mix.exs`'s version is read as a
release bump in flight and skipped — so without the copy the documented
self-host pin resolves nowhere and the compose boot check stops running instead
of failing.

**The copy goes after the first build, not before it.** A GHCR package grants
push rights to the repository that created it, so a package seeded by a user's
token is one the repo's own `build.yml` cannot write: it builds, then fails
with `denied: permission_denied: write_package`, and the fix is UI-only. Let
the build create the package; add the version tag to it afterwards.

### 5. 0043's Buzz graduation target becomes `managoat/fountain_buzz`

0043 decision 4 has `fountain_buzz` graduating to `BinaryBourbon/fountain_buzz`
— **not** `managoat/` — to mark that an extension is not a general-purpose
library. After this move that contrast names the account the project just left.
The distinction survives, carried by the name instead of the owner: both live
in the org, `managoat_*` is a library anyone can depend on, `fountain_*` is
Fountain's own. Nothing else in 0043 changes, and nothing graduates here.

## Cutover order

The one sequence that can break production. Steps 2 through 5 are a single
merge freeze: between the transfer and the home-cloud change, `main` must not
merge anything, because a build in that gap either fails (before the path
sweep) or publishes to a path Flux is not watching (after it).

0. **Prepare, before anything moves.** This ADR merged. The path sweep
   (#1795) reviewed, green and held as a draft — it carries the whole prose
   sweep with it, including the runtime strings users read and `CLAUDE.md`'s
   `gh api /repos/...` recipes. The home-cloud PR
   (jhgaylor/home-cloud#221: the OCIRepository `url`, the release-asset URLs
   the runner role and openclaw read, the Flux webhook receiver's note)
   reviewed and held the same way. Record prod's currently running image
   digest, and confirm `deploy/k8s`'s pin is a released tag, so nothing
   *needs* to deploy during the window.
1. **Freeze `main`.**
2. **Transfer** `BinaryBourbon/fountain` to `managoat`, and
   `BinaryBourbon/homebrew-tap` to `managoat/homebrew-tap`.
3. **Verify what survived, before merging anything.** The five repository
   secrets, the two Actions variables, the `github-pages` and `pypi`
   environments, the `Main Protection` ruleset — both its bypass actor and its
   numeric id, which `scripts/ci/require-checks.py` passes as a default — the
   required check names (`CI required`), Actions being enabled at all, and
   Dependabot. Recreate whatever did not transfer. GitHub's transfer
   documentation does not promise secrets, so treat every one of them as
   absent until seen. Separately: the `BinaryBourbon` **account** is the
   estate-medic bot identity, and it held Write on this repo by owning it.
   Grant it Write explicitly, or the bot's fix-PR flow stops working — and
   keep it non-admin, because "cannot approve its own PR" is what makes that
   flow safe.
4. **Merge the path sweep.** The first build publishes
   `ghcr.io/managoat/fountain:sha-<sha>` and, after it, the artifact. Confirm
   both packages are readable anonymously — the `OCIRepository` carries no
   `secretRef`, so Flux's fetch and a self-hoster's pull both are.
5. **Copy the released tags into the new namespace**, now that the packages
   exist and the repo owns them (decision 4 explains why this order and not the
   other one).
6. **Merge the home-cloud PR** and confirm Flux reconciles the new artifact and
   the pod pulls the new digest. Until this lands, prod runs the last old
   digest: safe, and not a deploy path.
7. **Re-point what lives outside both repos.** PyPI trusted publishing names
   the owner, the repo and the workflow filename
   (`python-sdk-publish.yml:5-6`) — update it or the next publish fails, and a
   failed publish is invisible to every gate here. npm provenance verifies
   `package.json`'s repository URL (`sdk-publish.yml:131`). Hex package links.
   The OIDC allow-claim in `managoat/review-loop-action`.
8. **Unfreeze.**

## After the move

What happened on 2026-09-10, in the order it happened, because three of these
were not predicted anywhere above.

**Transferred intact, verified rather than assumed:** all five repository
secrets, both Actions variables, the `github-pages` and `pypi` environments,
the `Main Protection` ruleset with the same numeric id (`21689465`, the one
`scripts/ci/require-checks.py` defaults to) and the same two required checks,
Actions enabled, the open pull request, and the tap's collaborators.

**1. `gitleaks-action` is licensed for organizations.** `Detect secrets` — one
of the two *required* checks — began failing on the first push after the
transfer with `[managoat] is an organization. License key is required.` Every
PR in the repo was blocked. The scanner is MIT and unmetered; only the action
wrapper is licensed, so #1798 dropped the wrapper for the pinned CLI over the
same commit ranges. Anything that gates merges and wraps a third-party action
is worth checking for a per-owner-type licence before a move like this.

**2. The ruleset's implicit bypass does not survive.** Post-transfer,
`bypass_actors` was `[]` and `current_user_can_bypass` was `never`, so
`gh pr merge --admin` was refused on a PR whose checks were all green — on a
repo whose convention is a solo admin merge. Re-declared as
`OrganizationAdmin / always`, with all four rules intact.

**3. The previous owner drops to the organization's base permission.** Owning a
repo is not a grant that can move, so `BinaryBourbon` — the estate-medic bot
identity — landed on `read` (the org's `default_repository_permission`) and
could no longer push. It now has write through a `managoat/engineering` team,
which also covers the tap. Two accounts with access to this repo are outside
collaborators and stayed that way; a team is not the complete access list.

**4. The packages came out public.** home-cloud's note that packages under
`managoat` are private on creation did not apply here: a public repository's
first push produced public `fountain` and `fountain-manifests` packages, both
anonymously pullable, so the UI step the runbook reserved was not needed.

**5. The Pages tombstone died, exactly as predicted.**
`binarybourbon.github.io/fountain/` now 404s and `managoat.github.io/fountain/`
serves, so the retired doc URLs the tombstone existed to redirect (#1011) are
gone. Re-publishing the tombstone under the org does not bring them back; only
the old host could.

**Unrelated but worth recording:** `builds.hex.pm` was returning gateway errors
through the whole window, which failed `setup-beam` in four jobs and
`mix local.hex` inside the image build. Re-runs fixed all of them. A cutover
day is a bad day to not know what your CI's external dependencies are.

## Consequences

- **Three things break, and we accept them.**
  `go install github.com/BinaryBourbon/fountain/cli/cmd/fountain@latest` stops
  working once `go.mod` declares the new path (the redirect resolves; Go then
  refuses the mismatched declaration). `binarybourbon.github.io/fountain/*`
  stops serving, because GitHub Pages does not follow a transfer redirect —
  and that is the tombstone whose only job is redirecting retired doc URLs
  (#1011); it gets rebuilt under the org or the old doc URLs die. Published
  self-host instructions pin the old image path, which keeps working but drifts
  from the docs until a reader upgrades.
- **A merge freeze of an hour or two**, during which no deploy can ship. It was
  about ninety minutes, most of it waiting on CI, and production never stopped
  serving: the old pods kept running the old digest until the new artifact
  reconciled.
- **`release_pin_test.exs` and the CLI/SDK tests are the completeness gate.**
  Several tests assert these strings
  (`apps/fountain/test/fountain/{release_pin,team/mcp,conversations/conversation_server}_test.exs`,
  `apps/fountain/test/fountain_web/live/environments_form_live_test.exs`,
  `sdk/typescript/test/resources.test.ts`, the `cli/` suites). A sweep that
  misses a file fails CI rather than shipping a dead URL.
- **Two things stay behind with the user account.** The GitHub **Project**
  (`users/BinaryBourbon/projects/1`, which `.agents/skills/fountain-project-gardener`
  drives) is owned by the account, not the repo, and no transfer moves it: it
  has to be rebuilt or copied under the org, and what a copy brings with it is
  worth checking before assuming the board survives — it was left where it is.
  And the `BinaryBourbon` account keeps its second job as the estate-medic bot
  identity, which is why its write access had to be granted again (cutover
  step 3, and *After the move* for how).
- **Bus factor improves** in the one place it was worst: the repo can have a
  second admin without handing over a personal account.
- **This ADR amends 0034, it does not contradict it.** The project is still
  called Fountain; its GitHub home is now the organization that already
  publishes its libraries.

## Alternatives considered

- **`managoat/managoat`, renaming the product into the repo** — implies
  renaming Fountain itself: the `:fountain` OTP app, the `fountain` binary,
  every `FOUNTAIN_*` env var, 100+ doc pages, three `fountain-template-*`
  repos. 0034 decided the project is not renamed, and nothing here changes
  that argument.
- **Rename the `BinaryBourbon` user account to `managoat`** — impossible (the
  org holds the login) and wrong anyway: it would drag 19 unrelated
  repositories and the account's own identity along.
- **Leave the repo and move only the packages** — GHCR writes are owner-scoped,
  so publishing to `ghcr.io/managoat/*` from a `BinaryBourbon` repo needs a
  cross-account PAT in CI. More credential, same fallout, later.
- **Fresh repo in the org plus a push** — loses 151 open issues, the PR
  history, the stars and every cross-reference in `decisions/`.
- **Do it gradually, one coordinate at a time** — the forced set cannot be
  gradual: the transfer invalidates every GHCR write at once. Gradual is
  exactly what the second table is for.

## Related

- 0034 — the project/product name split this move is tested against.
- 0037 / #1345 — the library graduations that put nine Fountain repos in the
  org first, and `scripts/graduate-library.sh`, which already writes
  `managoat/` URLs.
- 0032 / #304 — the manifest artifact and the Flux consumer whose URL is the
  riskiest line in the cutover.
- #1008 / #1011 — the Pages retirement and the tombstone that a transfer
  silently takes offline.

## Amendment, 2026-10-15: the project is renamed

[0082](0082-the-project-is-managoat.md) renames the project Managoat. The
alternative this file rejected first, `managoat/managoat` with the product
renamed, is now the plan, for the reason this file gave for rejecting it
turned around: 0034's edition split was why the project kept its name, and
with no hosted product the split describes nothing. 0082 does not take on
everything this file's alternative listed. The `:fountain` OTP application,
the Elixir modules and the database names stay; the binary, the `FOUNTAIN_*`
variables (kept as aliases), the image, the Go module and the SDK are renamed.

The owner-scoped coordinates in decision 2 stay `managoat`. Their names
change in 0082's third layer: `ghcr.io/managoat/managoat`,
`github.com/managoat/managoat/cli`, and `@managoat/sdk` in place of the
`@managoat/fountain-sdk` this file's second table named. Decision 4's rule
applies to the old image name: it is frozen, not deleted.
