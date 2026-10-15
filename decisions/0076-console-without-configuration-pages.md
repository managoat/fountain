---
type: ADR
title: "The console drops its agent, environment and vault pages and its in-app help"
description: "The console covers the dashboard, audit, API keys, account and admin; agents, environments and vaults are configured through the API, the CLI and client apps, and help is the manual."
tags: [product, console, docs]
status: stable
adr: "0076"
adr_status: "Accepted"
date: 2026-10-15
---

# 0076 — The console drops its agent, environment and vault pages and its in-app help

**Status:** Accepted, 2026-10-15, by the maintainer. Built. Amends
[0029](0029-agent-config-versioning.md) and
[0037](0037-component-libraries.md), as described under Consequences.

## Context

The console had pages to list, create and edit agents, environments and
vaults, an agent version history with a rollback button, and a curated
in-app help under `/help`. Each duplicated another surface:

- The Conversations app (managoat/demos) has its own Agents, Environments
  and Vaults pages on the same `/api` routes the CLI and the SDK use.
- The CLI creates and updates all three with `managoat apply`, lists and
  shows them with `managoat agent`, `managoat env` and `managoat vault`, and
  manages vault secrets with `managoat vault`. Deleting an agent or an
  environment is the app's or the API's.
- The manual is public, searchable and covers the same topics as
  `priv/help`, which was a second, smaller and older copy.

Two copies of a configuration form drift: the console's agent form had grown
its own model suggestions, credential prompts and provider selects that the
app had to match. The two copies of the help drifted too; `managoat apply`
and the secrets managers were documented in both with different details.

## Decision

1. **The console covers the dashboard, audit, API keys, account and admin.**
   `FountainWeb.AgentsLive.{Index,Form,Versions}`,
   `EnvironmentsLive.{Index,Form}` and `VaultsLive.{Index,Form}` are
   removed, with their routes, sidebar links, `g a` / `g e` / `g v`
   shortcuts and `FountainWeb.InferenceCredentialSave` (used only by the
   agent form). The old paths return the ordinary 404, as other retired
   browser paths do (`docs/concepts/surfaces.md`).
2. **Configuration lives in the API, the CLI and client apps.** The
   contexts (`Fountain.Agents`, `Fountain.Environments`, `Fountain.Vaults`)
   and every `/api` route are unchanged. An agent's version history is
   `GET /api/agents/:id/versions`; a vault secret's expiry is
   `managoat vault show` or the API. The human UIs are clients of the same
   `/api`, neither part of this repository:
   [Arugula](https://github.com/arugula-salad/arugula), the primary one
   (tracked in [#942](https://github.com/arugula-salad/arugula/issues/942):
   device-grant sign-in, following conversations, permission requests as
   cards; not yet built on 2026-10-15), and the Conversations app, kept as a
   second client. Each configures as much as it has built.
3. **The browser avatar route goes.** `GET /agents/:id/avatar`
   (session-authenticated) served only the agent pages.
   `/api/agents/:id/avatar` stays.
4. **The dashboard drops its agent, environment and vault counts.** It
   keeps the month's usage, what is running now and the recent
   conversations, and links out to the Conversations app; with no app
   configured it points at the CLI and the API.
5. **In-app help is the manual.** `FountainWeb.HelpLive.Show`,
   `Fountain.Help` and `priv/help/*.md` are removed (#2721). What
   `priv/help` had and the manual lacked moved into `docs/` (the manifest
   format and secret managers in `guides/manifests.md`, operator procedures
   into the operate guides, sandbox notes into the skill page). `/help`
   redirects to the manual and `/help/:topic` to the page that took the
   topic (`FountainWeb.HelpRedirectController`, a static map); an unknown
   topic goes to the manual's index.
6. **Device sign-in names its client.** `POST /api/auth/device` takes an
   optional `client_name`, which the approval page at `/device` shows as the
   client's unverified claim and which names the minted API key in place of
   `CLI login — <date>`. The CLI sends `managoat CLI on <hostname>`. This is
   the one change Arugula's sign-in needed here.

## Consequences

- **Rollback has no surface.** To go back to a version, write its `config`
  to the agent again (`PUT /api/agents/:id` or a manifest), which becomes
  the newest version. A rollback endpoint would be a new API decision.
- **0029 amended.** Its history page at `FountainWeb.AgentsLive.Versions` is
  gone; see the previous point for rollback. The rest stands.
- **0037 amended.** `Fountain.Help` is removed, not moved.
- **A deployment with no client app** configures agents, environments and
  vaults with the CLI, a manifest or the API.
- **Existing links.** Bookmarks and old emails that point at `/agents*`,
  `/environments*` or `/vaults*` get a 404; the retired-paths table in
  `docs/concepts/surfaces.md` names the destination for each. `/help` links
  keep working through the redirect.

## Alternatives considered

- **Keep read-only console pages.** Lists without forms still need the same
  queries, presenters and tests, for a view the apps already have.
- **Redirect the retired configuration paths to the app.** The conversation
  paths were redirected once and the redirects were removed (#2105); the
  app's URL is per deployment and may be empty. A 404 and a documented
  destination is simpler.
- **Add a rollback endpoint now.** An API and SDK change with its own
  decision, and nobody asked for it outside the console. Deferred, not
  built.
- **Keep `/help` as a 404.** The redirect is one small controller and keeps
  links in old agent instructions working.

## History

- 2026-10-15 — Decided and built: configuration pages and in-app help removed from the console (#2721, #2732).
- 2026-10-15 — `Agents.rollback_agent/3`, left unreachable by the versions page's removal, deleted (#2733).
- 2026-10-15 — The secret-expiry email, which this ADR had changed to name the `set-secret` command instead of a page, was removed with the mail changes ([0011](0011-self-host-first-admin-bootstrap.md)).
- 2026-10-15 — Arugula named the primary human UI, the Conversations app a second client; `client_name` added to the device grant.
