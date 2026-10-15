---
type: ADR
title: "The project is Managoat"
description: "The open-source project is renamed from Fountain to Managoat: the name a person reads everywhere, and the public names: the CLI binary managoat, MANAGOAT_* variables (FOUNTAIN_* still read as deprecated aliases), the SDK @managoat/sdk, the image, the Go module and the repository managoat/managoat. Elixir modules (Fountain.*, FountainWeb.*), the :fountain OTP app, apps/fountain/ and the database and role names stay as internal identifiers. PRODUCT_NAME and BRAND_ASSETS_URL are removed: the name and the icons are built in, and a deployment that wants another brand forks. Supersedes 0034's and 0048's 'the project is not renamed'. Partly built: the brand knobs, the edition-split copy and the icons in the PR that adds this file, and the prose rename after it; the public names with their aliases, and the repository rename, are not."
tags: [brand, open-source, product, release]
status: stable
adr: "0082"
adr_status: "Accepted"
date: 2026-10-15
---

# 0082 — The project is Managoat

**Status:** Accepted, 2026-10-15 (Jake). Partly built: layer 1 of three (below)
lands in the PR that adds this file, and layer 2 in the one after it. Layer 3
is not built.
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

| What | Now | After |
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

**It lands in three layers**, each a PR in a stack:

1. **The brand and the edition split** (the PR that adds this file). The
   knobs, `Fountain.Brand`, the `BrandAssets` plug and `FountainWeb.CSP` (its
   only user) are deleted; the console, the emails and the Open Graph card say
   Managoat; the built-in icons are the Managoat bundle, which `site/` also
   serves itself under `/site/images/brand/`. Every sentence that described
   Managoat as a hosted Fountain or as running on Fountain is removed.
2. **The prose.** The manual, the README, the site, the CLI's help text and
   the SDK's documentation call the project Managoat. So do the API
   description, the console's and the API's messages, and the NOTICE. What
   still says Fountain is an identifier (the SDK's `Fountain` and
   `FountainError` classes, the alert names, the ACP agent name), which is
   left to layer 3, and code comments, test names and migrations, which are
   internal like the module names.
3. **The public names**, as in the table, each old name kept working for a
   deprecation window: the `FOUNTAIN_*` variables are read when the
   `MANAGOAT_*` one is unset, the image is published under both names, and
   the repository rename relies on GitHub's redirect.

## Consequences

- An instance that set `PRODUCT_NAME` to something other than Managoat now
  says Managoat, and one that set `BRAND_ASSETS_URL` now shows the built-in
  icons. Both are told at boot. An instance that set neither used to say
  Fountain and now says Managoat.
- `img-src` is the router's `@csp` again, with no runtime widening.
- Until layers 2 and 3 land, Fountain and Managoat both appear: the console
  and the site say Managoat while the CLI is `fountain` and the manual still
  mostly says Fountain. Layer 1 rewrote a sentence only where removing the
  edition split left it wrong.
- Search: "fountain" stops finding the project once the repository and the
  manual are renamed. GitHub's redirect keeps clones, links and
  `managoat/fountain#N` references working.
- The deprecation window for `FOUNTAIN_*` is not decided here. Removing the
  aliases is a breaking change with its own upgrade note when it happens.

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
