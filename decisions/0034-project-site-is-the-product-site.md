---
type: ADR
title: "The open-source project has no site of its own; managoat.com and /docs carry it"
description: "Retired 2026-10-12: Fountain is no longer sold as a hosted service, so there is no product site for the project to share. With the hosted instance branded Managoat, Fountain the AGPL project keeps its name but gets no separate domain or GitHub Pages site. The product site is the project site: one 'Open source' page under /docs states the licence split and links the repo, and the README points back. Amended 2026-09-14: the marketing pages are a static site of their own (managoat/site) on the same host, in front of the app at the ingress; the app serves the front door, the legal pages and /docs. Confirmed 2026-09-14: goatherd's repository and README are not a second Fountain project site. Amended 2026-10-15: the pages fold back into site/ in this repository, still a static build with its own image, because the sales copy is gone and path-filtered CI keeps a site edit off the server suite; six pages were cut and three moved into the manual. Amended 2026-10-15 again (0081): the manual is part of that static build too; the app no longer serves /docs and redirects it there. Amended 2026-10-15 by 0082: the project is renamed Managoat, so the edition split between Fountain and a hosted Managoat, and 'the project is not renamed', no longer hold."
tags: [open-source, docs, brand, product]
status: deprecated
adr: "0034"
adr_status: "Retired"
date: 2026-08-25
generated: { by: openai/gpt-6, at: 2026-09-14T09:12:00Z }
verified: { by: human:jhgaylor, at: 2026-08-25T22:00:00-04:00 }
---

# 0034 — The open-source project has no site of its own; managoat.com and /docs carry it

**Status:** Retired 2026-10-12; see the addendum at the end. Amended 2026-10-15: the pages are back in this repository, under `site/`. Amended 2026-10-15 again: the manual is part of that build, and the app no longer serves `/docs` ([0081](0081-the-manual-is-a-static-build.md)). Amended 2026-10-15 a third time: the project is Managoat ([0082](0082-the-project-is-managoat.md)). The text above the addendum is history. Was: Accepted, built in the PR that adds this file. Amended
2026-09-14 (see the end): the marketing pages left the app for a static site
on the same host. Nothing described here is unbuilt.

## Context

The hosted instance moved from `fountain.inevitable.fyi` to `managoat.com`
(#1177). The console brands itself from the host, so the hosted product now
presents as *Managoat*, while the repo, the CLI (`fountain`), the SDK
(`@agentshit/fountain-sdk`), the Docker image and every ADR still say
*Fountain*. Before the move, the product URL and the project name agreed and
nobody had to decide which was which. After it, an obvious question appears:
where is the open-source project's home? There is no `fountain.dev`, the
GitHub Pages docs site was retired in #1008 (its domain is a redirect
tombstone into `/docs`, #1011), and the only thing on the internet that says
"Fountain is open source" is the README's licence table.

The relicensing to AGPL (0027) made the open-source identity load-bearing:
the copyleft argument only works if people can find the project, read the
licence split, and self-host without the hosted brand in the way.

Three patterns exist among open-core companies:

1. **One domain, one brand** — PostHog, Sentry, Supabase, Cal.com.
   `posthog.com` is marketing, docs, blog and the login for the cloud
   product. "Open source" is a section and a badge, not a site. The repo
   README links back to the product domain.
2. **One domain, two labelled halves** — GitLab, Grafana, Mattermost. The
   project identity is carried by an *edition* (CE/EE) or a path
   (`grafana.com/oss/grafana`), not a second domain.
3. **Separate project and company domains** — Discourse
   (`discourse.org`/`.com`), Elastic once (`elasticsearch.org`, dropped),
   foundation projects (CNCF, OpenTofu). This is the pattern that looks
   like "a project site". Outside a governance split it has mostly been
   collapsed back into pattern 1, because it means two sites to keep
   current, two SEO targets and a permanent "which one do I go to?".

## Decision

Pattern 1, with pattern 2's naming:

- **`managoat.com` is the site.** Marketing, docs, login. It says the server
  is open source and links the repo. There is no second domain and no
  GitHub Pages site for the project, and buying one is out of scope until
  there is a governance reason (a foundation, a second maintainer with
  standing) rather than a branding one.
- **`/docs` is the project manual.** It already is: self-hosting, the CLI,
  the SDK, the API, the sandbox contract. A "project site" would be a copy
  of it, and #1008 retired the last second copy because it went stale.
- **The GitHub repo is the project's home.** The README is the project
  front page. It says what Fountain is, self-host in three lines, the
  licence split, and links the hosted instance for people who do not want
  to run it.
- **The names split by edition, not by domain.** *Fountain* is the AGPL
  server, the CLI and the SDK. *Managoat* is one hosted instance of it.
  `ee/` is the Elastic-2.0 part. The project is not renamed.
- **One page states all of this: `docs/open-source.md`.**
  Published at `/docs/open-source`, in the nav next to Self-host. It is the
  URL to hand to anyone who asks "is this open source?" and the place the
  README's licence section points at for the long form. Grafana's
  `/oss/grafana` is the model.

## Consequences

- No new domain, DNS, cert, workflow or publisher. The docs guardrails
  (nav test, link and anchor test, style script, STE linter) cover the new
  page like any other.
- The README and `/docs` must both keep saying "Managoat is a hosted
  Fountain" or the split stops being legible. The README's licence section
  now links the page; the page links the README's licence table's targets
  (`LICENSE`, `ee/LICENSE`, `NOTICE`, 0027).
- Marketing copy on the hosted homepage is free to lead with Managoat, but
  the "open source" sentence and the repo link stay above the fold. That
  copy lives with the hosted instance's branding and is not versioned here
  (since the 2026-09-14 amendment, literally: it is in `managoat/site`).
- Search: "fountain agent sandbox" resolves to the repo and `/docs`;
  "managoat" resolves to the product. That is the intended split and the
  reason not to rename.

## What would change this

A second organisation running or contributing to Fountain at a scale where
neutral ground matters, or a foundation transfer. Either is the governance
reason that justifies pattern 3, and it would come with the second maintainer
needed to keep a second site alive.

## Related

- 0027 — the AGPL relicensing that makes the open-source identity matter.
- 0032 — the hosted overlay leaving the repo; the same "product and project
  are different things, kept in one place each" line.
- #1008 / #1011 — the GitHub Pages retirement and tombstone; the last time a
  second publisher for the same content was tried.

## Amendment, 2026-09-14: the marketing pages are a static site on the same host

The decision above said "one domain" and, implicitly, "the app serves both":
the pitch, the campaign pages, integrations, built-with, self-host, the
questions page and the case study were Phoenix templates inside the AGPL
server, gated by `MARKETING_SITE` so a self-host never rendered them. That put
about 9,900 lines of one deployment's sales copy and its tests in the
open-source repo, ran the engine's suite on every headline edit, and rebuilt
the image for every one (#1399).

What changed:

- **The pages live in [managoat/site](https://github.com/managoat/site)**,
  rendered to static HTML by a small Elixir project over the same HEEx
  templates, and served by nginx. What the app read at request time (brand,
  prices, the installed extensions, the session for the nav) is a constant
  there.
- **Same host, path-routed.** Traefik (home-cloud, `managoat-site`) sends `/`,
  `/launch`, `/oss-launch`, `/buzz-launch`, `/integrations`, `/built-with`,
  `/self-hosted`, `/faq`, `/code-review-bot`, `/case-studies/*` and `/site/*`
  on `managoat.com` to the site and everything else to the app. "One domain"
  stands; "the app serves both" does not.
- **The app keeps what is not marketing:** a plain front door at `/`
  (`FountainWeb.FrontDoorController`), the operator's legal pages
  (`Fountain.Legal`, #517) and `/docs`. `MARKETING_SITE` survives with one
  job: whether the manual's chrome links the site's pages.
- **The docs stay here.** Phase 1 of #1399 (the manual leaving the image) is
  not part of this; the three cross-repo couplings it would create are the
  reason marketing went first.

Trade-offs accepted: a signed-in reader of `managoat.com/` sees "Sign in"
rather than "Go to app" (the login route forwards them); the pricing copy is
a constant that must be changed with the deployment's `CREDIT_*` variables;
the `/self-hosted` env-var table lost its in-repo guard, which now reads
`docs/reference/feature-status.md` instead.

## Confirmation, 2026-09-14: a repository is not a project site

[`managoat/goatherd`](https://github.com/managoat/goatherd) is another public
artifact under the organization, with its own README. That is consistent
with this ADR: a repository and its usage instructions do not create a
second Fountain project site. Fountain's project home remains
`managoat/fountain`, its manual remains `/docs`, and `managoat.com` remains
the shared product/project domain. The marketing repository `managoat/site`
and the app's manual retain the boundary in the amendment above.

[ADR 0055](0055-hosted-fountain-and-local-control-planes.md) records the
hosted/local boundary from [#1516](https://github.com/managoat/fountain/issues/1516).
goatherd's README documents its own application; it does not become
Fountain's onboarding page or a second publisher for Fountain's manual.

## Addendum — 2026-10-12: retired, there is no hosted product to carry the project

Fountain is no longer sold as a hosted service (2026-10-12). This ADR answered
a question that only a hosted product raises: where does an open-source
project live when its hosted instance has a different brand? With no hosted
product to sell, *Managoat* is not a product, and `managoat.com` is not the
project's product site. It is one Fountain instance, the maintainer's own,
which serves the manual at `/docs` the way every instance does.

What still holds, now because it is simply true and not because this ADR
decided it:

- The GitHub repository is the project's home, and its README is the front
  page.
- `/docs` is the manual, served by the app. The absolute links in the
  changelog and in other public material point at `managoat.com/docs`
  because that instance publishes the current manual.
- `docs/open-source.md` states the licence. It no longer describes an
  `ee/` part: `ee/` was deleted with billing (ADR 0010, retired).

What no longer holds: "managoat.com is the site" as a sales and login
destination, the edition split between *Fountain* and a hosted *Managoat*,
and the 2026-09-14 amendment's note that the site's pricing copy must follow
the `CREDIT_*` variables, which no longer exist. Whatever `managoat/site`
says is that repository's concern.

## Amendment, 2026-10-15: the pages fold back into this repository

The managoat.com pages moved back from `managoat/site` into `site/` in this
repository on 2026-10-15. They are still a static build: the same Mix project
(`mix site.build`), nginx, their own image `ghcr.io/managoat/site`, and the
Traefik path split in `site/k8s/ingressroute.yaml`. They did not become
Phoenix templates again, and the app's front door still answers 404 for the
paths it no longer serves.

Neither reason the 2026-09-14 amendment gave for the split still holds.

- **"The open-source repo should not carry one deployment's sales copy."**
  There has been no sales copy since 2026-10-12. Fountain is not sold, the
  pages sell nothing, and the call to action is a mail to the maintainer.
- **"A headline edit should not run the engine's suite or rebuild its image."**
  Path-filtered CI does that now. `scripts/ci/changes.py` puts a `site/`-only
  pull request on the short path, which skips the server suite.
  CI's `site` job tests and renders the site, and the site's image is built
  (by `.github/workflows/site.yml`) only when `site/` changes. `build.yml` ignores `site/`, so a
  site-only commit does not rebuild Fountain's image. A push to `main` still
  runs the whole CI plan, as every push to `main` does.

The split also cost more than it saved. Of the six content commits in
`managoat/site` after the split, four were cleanup after something Fountain
cut: the retired protocols (site#4), the hosted product (site#7), the team
feature (site#10) and other removed features (site#11). The other two added
and then removed an animation (site#8, site#9). Each cleanup was a second
change in a second repository, made after the change that caused it. Five
links into the manual had also gone dead, because the site's link test let
every `/docs` link through and only a manual task checked them against
production. In this repository the test checks each `/docs` link against
`docs/nav.yml` and the pages on disk.

Six pages were cut, not moved: the open-source launch page, the case study,
the code review bot, self-host, the questions page and integrations. Three
things they held moved into the manual:

- the ownership boundaries and running costs, into `docs/self-hosting.md`;
- the security answers and their limits, into `docs/reference/security.md`;
- the editor list, into `docs/integrations/editors.md`.

The home page and the list of apps built on the API stay.

Deployment changes shape. The site repository committed each image pin back
to its own `main`. This repository's ruleset refuses that push. So `site.yml`
publishes `site/k8s`, with the image pinned, as an OCI artifact
(`ghcr.io/managoat/site-manifests`), which is the shape `publish-manifests.yml`
uses for the app. Home-cloud's `managoat-site` Flux source has to change from
the site repository to that artifact. Until it does, the cluster keeps serving
the last image `managoat/site` built. That repository is not archived.

The 2026-10-12 addendum says `docs/open-source.md` states the licence. That
page no longer exists. The licence is in the Licence section of
`docs/self-hosting.md`.

## Amendment, 2026-10-15: the manual joins the static build

Two statements above stop holding the same day: the 2026-09-14 amendment's
"the docs stay here", in the sense of the app serving them, and the
2026-10-12 addendum's "`/docs` is the manual, served by the app". The
markdown stays in `docs/` in this repository. What changed is who renders
it: `site/` builds it into static pages at the same URLs, beside the home
page, and Traefik sends `/docs`, `/docs/*`, `/llms.txt`, `/llms-full.txt`
and `/skill` on managoat.com to the site. The app answers those paths with a
permanent redirect to `DOCS_URL`, managoat.com by default, on every other
deployment. "One domain, one manual" still holds; "served by the app" does
not. [0081](0081-the-manual-is-a-static-build.md) records why and what a
self-hosted instance gives up.

## Amendment, 2026-10-15: the project is Managoat

[0082](0082-the-project-is-managoat.md) renames the project. Two statements
above stop holding: the Decision's "the names split by edition, not by
domain ... The project is not renamed", and the Consequences' "the README and
`/docs` must both keep saying 'Managoat is a hosted Fountain'". The 2026-10-12
addendum had already said the split no longer held; what remained of it (the
`PRODUCT_NAME` and `BRAND_ASSETS_URL` brand override, the site's
"Managoat runs on Fountain" and "Built on Fountain" copy, and the self-hosting
page's "Fountain is the server, Managoat the organization") is removed with
0082's first layer. The repository
is still the project's home and `managoat.com` still publishes the manual.
