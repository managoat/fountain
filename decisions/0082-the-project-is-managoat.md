---
type: ADR
title: "The project is Managoat"
description: "The project is named Managoat in every public name (CLI, MANAGOAT_* variables, SDK, image, Go module, repository); Elixir modules, the OTP app and database names stay Fountain."
tags: [brand, open-source, product, release]
status: stable
adr: "0082"
adr_status: "Accepted"
date: 2026-10-15
---

# 0082 — The project is Managoat

**Status:** Accepted, 2026-10-15 (Jake), and built in three layers (#2769,
#2774, #2790); the repository is `managoat/managoat`. Not built: removing the
deprecated Fountain names (#2776).
**Amends:** [0034](0034-project-site-is-the-product-site.md) ("the names split
by edition"; "the project is not renamed") and
[0048](0048-the-repo-moves-to-the-managoat-organization.md) ("the repo keeps
its name"; the `managoat/managoat` alternative it rejected).

## Context

Two names have described one thing since the hosted instance moved to
`managoat.com` (#1177). [0034](0034-project-site-is-the-product-site.md)
made the split deliberate: *Fountain* was the AGPL engine, the CLI and the
SDK, and *Managoat* was one hosted instance of it, as GitLab CE is to
gitlab.com. [0048](0048-the-repo-moves-to-the-managoat-organization.md)
moved the repository into the `managoat` organization and said again that the
project keeps its name, rejecting `managoat/managoat` because 0034 had
decided against a rename.

The reason for the split is gone. Since 2026-10-12 Fountain is not sold as a
hosted service: there is no billing, no sign-up, and `managoat.com` is the
maintainer's own instance (0034's retirement addendum). With nothing hosted
to sell, "Fountain is the engine, Managoat a hosted instance of it" no longer
describes anything. What it left behind is copy and code that only made
sense with a hosted product in front of the engine:

- the console read its name from `PRODUCT_NAME` (default "Fountain") and its
  icons from `BRAND_ASSETS_URL` (`Fountain.Brand`,
  `FountainWeb.Plugs.BrandAssets`, and a runtime widening of the CSP's
  `img-src` for the bundle's origin), so that one instance could wear the
  Managoat brand while every other said Fountain;
- the site's `Site.Brand.engine/0` and `hosted?/0`, and sentences such as
  "Managoat runs on Fountain, an open-source server you can run yourself"
  and "Built on Fountain" in its footer;
- `docs/self-hosting.md` telling a reader that Fountain is the software and
  Managoat only the organization and the domain.

A reader arriving at `managoat.com`, the GitHub organization, or the console
of the maintainer's instance meets Managoat. They then install `fountain`,
set `FOUNTAIN_API_KEY`, import a `Fountain` client and read a manual about
Fountain. One name is cheaper to explain than two, and the name people
already see first is Managoat.

## Decision

**The project is Managoat.** Everywhere a person reads the product's name
(the console, the emails, the site, the manual, the README, the CLI's help,
the SDK's documentation), it says Managoat.

**The public names change with it:**

| What | Before | After |
|---|---|---|
| CLI binary | `fountain` | `managoat` |
| Environment variables | `FOUNTAIN_*` | `MANAGOAT_*`; each `FOUNTAIN_*` still read as a deprecated alias |
| TypeScript SDK | `@managoat/fountain-sdk` | `@managoat/sdk` |
| Container image | `ghcr.io/managoat/fountain` | `ghcr.io/managoat/managoat` |
| Go module | `github.com/managoat/fountain/cli` | `github.com/managoat/managoat/cli` |
| Repository | `managoat/fountain` | `managoat/managoat` |

**The internal identifiers stay:** the Elixir modules (`Fountain.*`,
`FountainWeb.*`), the `:fountain` OTP application, `apps/fountain/`, and the
database and role names. Renaming them changes no behaviour anyone can see,
touches nearly every file and every open branch, and on the database side is a
migration with its own failure modes on every running instance. They are
names a contributor reads, and a contributor can be told once. The folded-back
libraries in `apps/fountain/lib/managoat/` keep their `Managoat.*` names; the
overlap is a coincidence of the two histories, not a convention for new code.

**There is no brand override.** `PRODUCT_NAME` and `BRAND_ASSETS_URL` are
removed. The console's name and icons are Managoat's and are built into the
release (`apps/fountain/priv/static`). A deployment that sets either variable
gets a warning at boot and is otherwise unaffected. An operator who wants
another name forks; a configuration switch for one deployment's look is not
worth a module, a plug and a CSP exception in everyone's server.

**It landed in three layers**, each a PR in a stack:

1. **The brand and the edition split** (#2769). The
   knobs, `Fountain.Brand`, the `BrandAssets` plug and `FountainWeb.CSP` (its
   only user) are deleted; the console, the emails and the Open Graph card say
   Managoat; the built-in icons are the Managoat bundle, which `site/` also
   serves itself under `/site/images/brand/`. Every sentence that described
   Managoat as a hosted Fountain or as running on Fountain is removed.
2. **The prose** (#2774). The manual, the README, the site, the CLI's help text and
   the SDK's documentation call the project Managoat. So do the API
   description, the console's and the API's messages, and the NOTICE. What
   still says Fountain is an identifier (the SDK's `Fountain` and
   `FountainError` classes, the alert names, the ACP agent name), which is
   left to layer 3, and code comments, test names and migrations, which are
   internal like the module names.
3. **The public names** (#2790), as in the table, each old name kept working for a
   deprecation window: the `FOUNTAIN_*` variables are read when the
   `MANAGOAT_*` one is unset, the image is published under both names, and
   the repository rename relies on GitHub's redirect.

## Consequences

- An instance that set `PRODUCT_NAME` to something other than Managoat now
  says Managoat, and one that set `BRAND_ASSETS_URL` now shows the built-in
  icons. Both are told at boot. An instance that set neither used to say
  Fountain and now says Managoat.
- `img-src` is the router's `@csp` again, with no runtime widening.
- Search: "fountain" no longer finds the project, since the repository and
  the manual are renamed. GitHub's redirect keeps clones, links and
  `managoat/fountain#N` references working.
- The deprecation window's length is not decided here. Removing the aliases
  is a breaking change with its own upgrade note when it happens (#2776).

## Layer 3: the public names and their deprecation window

Every name in the table changed, and each old one keeps working, so an
upgrade breaks nothing that worked the day before. The old names are read
or published **in addition to** the new ones, never instead of them, and a
later release removes them all at once (#2776). Until then:

- **Server configuration.** A `MANAGOAT_*` variable the server reads falls
  back to its `FOUNTAIN_*` name when unset, with a warning at boot. Only
  `MANAGOAT_BUILD_SHA` is read today, and the image sets it.
- **The sandbox contract.** Every variable Managoat hands a sandbox is
  exported under both names (`MANAGOAT_BASE_URL` and `FOUNTAIN_BASE_URL`,
  and so on for `_TOKEN`, `_CONVERSATION_ID`, `_SANDBOX_ID`, `_SKILLS_DIR`),
  because agents, skills, setup scripts and older CLIs inside a sandbox read
  the old ones, and a sandbox outlives a server upgrade. A session is tagged
  with both conversation-id names, and a tag under either is recognised, so
  a session from before the upgrade reattaches and one from after it survives
  a rollback. `X-Managoat-Parent-Conversation-Id` is the header;
  `X-Fountain-Parent-Conversation-Id` is still read.
- **The CLI** is `managoat`, and reads `MANAGOAT_*` before each `FOUNTAIN_*`
  (warning on stderr when it reads an old one) and
  `~/.managoat/credentials` before `~/.fountain/credentials`; its first write
  creates the new file. Releases also attach the binaries as
  `fountain-<os>-<arch>`. The Homebrew formula is `managoat`, the tap's
  `formula_renames.json` maps `fountain` to it, and the formula links a
  `fountain` command to the binary. As an ACP agent it is `managoat`, and it
  accepts the old auth method id.
- **The SDK** is `@managoat/sdk` 11.0.0, a major version. `Fountain`,
  `FountainError` and their types remain as deprecated aliases, and it reads
  the same variables and files the CLI does.
- **The image** is pushed to `ghcr.io/managoat/managoat` and every tag also
  to `ghcr.io/managoat/fountain`; the manifest artifact goes to
  `ghcr.io/managoat/managoat-manifests` and is mirrored to
  `ghcr.io/managoat/fountain-manifests`, which the maintainer's Flux source
  reads until it is moved. Compose reads `MANAGOAT_IMAGE_TAG`, then
  `FOUNTAIN_IMAGE_TAG`.
- **The skill** is `managoat`, at `/skills/managoat/SKILL.md`, and is still
  served at `/skills/fountain/SKILL.md`. The skill bundled into each sandbox
  replaces its old `fountain` directory on the next reconcile.
- **The repository** links say `managoat/managoat`; GitHub redirects the old
  URL. Decision records and frozen changelogs
  keep the URLs they were written with.

Left as they were, as internal or as not worth a migration: the metric names
(`fountain_*`) and `OTEL_SERVICE_NAME`'s default, the Kubernetes namespace
and resource names, the `fountain-conversations` OAuth client id (a registered
client in every deployment that runs the conversations app), the E2B
template name, the skills manifest file in a sandbox, and the ACP extension
methods (`_fountain/...`) between the server and the runtimes.

## Alternatives considered

- **Keep the split** (0034). It described a hosted product that no longer
  exists, and kept a brand override whose one user was the maintainer.
- **Rename everything, internal identifiers too.** Most of the cost and
  none of the benefit: nobody running or calling Managoat sees a module name,
  and the database rename is a migration on every instance.
- **Keep `PRODUCT_NAME` with a Managoat default.** It keeps the plug, the
  CSP exception and the tests for a feature whose purpose, letting one hosted
  instance wear a brand the engine did not, is gone. A fork can change one
  string.
- **Name only, public names unchanged.** The mismatch a reader meets (read
  Managoat, install `fountain`) is the problem this decision solves.

## History

- 2026-10-15 — Accepted: the project is Managoat; public names change with deprecated aliases, internal identifiers stay. Amends [0034](0034-project-site-is-the-product-site.md) and [0048](0048-the-repo-moves-to-the-managoat-organization.md).
- 2026-10-15 — Layer 1, the brand and the edition split, built (#2769).
- 2026-10-15 — Layer 2, the prose, built (#2774).
- 2026-10-15 — Layer 3, the public names with their deprecation window, built (#2790); the repository renamed to `managoat/managoat`.
