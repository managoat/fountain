---
type: ADR
title: "The manual is a static build in site/, not served by the server"
description: "docs/ is a static build in site/ published at managoat.com/docs; the server serves no manual and redirects its old paths there."
tags: [docs, site, deploy, ci]
status: stable
adr: "0081"
adr_status: "Accepted"
date: 2026-10-15
---

# 0081 — The manual is a static build in site/, not served by the server

**Status:** Accepted, 2026-10-15 (Jake). Built in the PR that adds this file.
**Amends:** [0034](0034-project-site-is-the-product-site.md) ("the docs stay
here", "`/docs` is the manual, served by the app") and
[0037](0037-component-libraries.md) (`managoat_docs` is no longer a
dependency).

## Context

Since #1008 the manual (`docs/`) has been compiled into the server:
`Fountain.Docs`, one `use` line over the `managoat_docs` hex library, embedded
the pages at compile time, `FountainWeb.DocsController` rendered them at
`/docs`, and `FountainWeb.LlmsController` built `/llms.txt`, `/llms-full.txt`
and `/skill` from the same pages. That made the manual part of the image: the
Dockerfile copied `docs/` and `CHANGELOG.md` and baked tree-sitter parsers
for the highlighter, because the pods run on a read-only root filesystem
where a parser cannot be fetched at runtime; `build.yml` rebuilt the image for
every docs change (#770); and the docs CI job compiled the umbrella and
started Postgres to test markdown.

[#1399](https://github.com/managoat/fountain/issues/1399) planned moving the
manual to a static host ("phase 1") and was closed, not planned, for reasons
that have since stopped holding:

- **The coupling was cross-repository.** The CLI parity test, the
  configuration guards, the changelog snippet and the primitives-diagram test
  all read `docs/` as code, and the static site lived in `managoat/site`. The
  site came back into this repository as `site/` on 2026-10-15 (0034's
  amendment of that date), so the manual can move to it without leaving the
  repository; everything that reads `docs/` still reads it in place.
- **Docs merges cost nothing anyone waited on.** Since 2026-10-15 prod deploys
  releases, not merges ([0080](0080-prod-deploys-releases.md)). A docs fix
  compiled into the server now waits for the next release to reach
  managoat.com, where before it shipped on merge.

## Decision

1. **`site/` renders the manual.** `mix site.build` writes one page per slug
   of `docs/nav.yml` at the same URLs as before (`/docs`, `/docs/<slug>`), the
   search index as `/docs/search-index.json`, and the llms files
   (`/llms.txt`, `/llms-full.txt`, `/skill`, `/skills/fountain/SKILL.md`),
   with `https://managoat.com` as their base. The parts of `managoat_docs`
   the build needs (the nav parser, snippet includes, admonitions, link
   rewriting, the sanitising renderer, heading extraction) are plain
   modules in `site/lib/site/` (`Site.Manual`, `Site.Markdown`), with no
   `use` macro or case template, since there is one consumer. The page
   shell (sidebar, search, copy buttons) wears the site's layout.
2. **Highlighting happens at build time and is strict.** A fence must name a
   Lumis language whose parser loads, or one of a short plaintext list;
   anything else fails the build. The read-only-filesystem parser problem no
   longer exists, because nothing is highlighted at runtime.
3. **The guardrails are the site's tests.** `site/test/manual_test.exs`,
   `markdown_test.exs` and `docs_build_test.exs` carry what `docs_test.exs`,
   `docs_controller_test.exs`, `llms_controller_test.exs` and
   `Managoat.Docs.GuardrailCase` checked, plus the renderer's hostile-input
   tests. Tests that read `docs/` files without the renderer (the CLI parity
   test, the configuration guards, the `/help` redirect targets) stay where
   they are.
4. **The server redirects.** `/docs`, `/docs/*`, `/llms.txt`,
   `/llms-full.txt`, `/skill` and `/skills/fountain/SKILL.md` answer 301 to
   the same path at `DOCS_URL` (`config :fountain, :docs_url`, default
   `https://managoat.com`). `/help` topics go straight to their page there.
   In-app links still say `/docs/...`. On managoat.com Traefik sends those
   paths to the site (`site/k8s/ingressroute.yaml`), so they never reach the
   app; a `DOCS_URL` on the request's own host answers 404 rather than loop.
5. **The image holds nothing for the manual.** No `COPY docs`, no
   `COPY CHANGELOG.md`, no parser baking, no `managoat_docs`, `mdex` or
   `lumis`. The first-request snippets that `Fountain.FirstRequest` reads at
   compile time and the manual includes moved from `docs/snippets/` to
   `apps/fountain/priv/first_request/`. The external `SKILL.md` moved to
   `site/priv/llms/`. `build.yml` ignores `docs/**` and `CHANGELOG.md`
   again, which is safe now that the image contains neither.
6. **CI.** The `site` job is the manual's gate. It is selected by a change to
   `docs/`, `site/`, or a file the manual includes or its tests read
   (`MANUAL_SOURCES` in `scripts/ci/changes.py`), and on main it republishes
   the site when what it renders changed. The `docs` job keeps only the CLI
   reference parity check, with no Elixir and no Postgres.

## Consequences

- **A self-hosted instance has no manual of its own.** Its `/docs` redirects
  to managoat.com. Offline, or behind a firewall that blocks managoat.com,
  there is no manual; `docs/` in the checkout, or `mix site.build` at the
  release's tag, is the fallback, and `DOCS_URL` points the redirects at a
  copy someone publishes.
- **The published manual describes `main`, not the release an instance
  runs.** It used to be the same commit as the server serving it. It can now
  be ahead of every release. `docs/index.md` and `docs/self-hosting.md` say
  so, and point at `docs/` at the release's tag for the matching text.
- **The llms files name managoat.com,** not the instance. They used to embed
  the instance's `PUBLIC_URL`; an agent reading them is now told that every
  instance serves its own `/api/openapi.json`.
- **A docs fix reaches managoat.com on merge,** through `site-publish` and
  Flux, without a release or a server rollout.
- **The release bump does not touch the manual.** Its commit changes only the
  version pins; `CHANGELOG.md` is frozen (release notes are on GitHub
  Releases), so a release has nothing for the site to republish. An edit to
  `CHANGELOG.md` lands by pull request and republishes on merge like any
  other docs change.
- **Ordering at rollout.** The site and its ingress route deploy on merge,
  so managoat.com serves the static manual from then on, while the running
  server still contains its compiled copy, unreachable there, until the next
  release replaces it with the redirects.
- **`managoat_docs` has no consumer.** Its hex releases are retired and
  `managoat/managoat_docs` is archived (#2771).

## Alternatives considered

- **Keep compiling the manual into the server** — the status quo. Every docs
  fix waits for a release (0080), and the image keeps carrying parsers for a
  page nobody on a self-host is required to read from it.
- **Keep `managoat_docs` and `use` it from `site/`** — #1399's original shape.
  One consumer does not need a macro, a case template or a hex release cycle,
  and the library's Dockerfile checks would have nothing to check.
- **Serve the manual from both** — two publishers for one manual is what
  #1008 retired.
