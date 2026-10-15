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

**Status:** Accepted, 2026-10-15, by the maintainer. Built in the PR that
adds this ADR. **Amends:** [0029](0029-agent-config-versioning.md) and
[0037](0037-component-libraries.md), as described under Consequences.

## Context

Fountain's console had pages to list, create and edit agents, environments
and vaults, an agent version history with a rollback button, and a curated
in-app help under `/help`. Every one of these duplicated another surface:

- The **Conversations app** (managoat/demos) has its own Agents,
  Environments and Vaults pages (`#/agents`, `#/environments`, `#/vaults`)
  on the same `/api` routes the CLI and the SDK use.
- The **CLI** creates and updates all three with `fountain apply`, lists
  and shows them with `fountain agent`, `fountain env` and `fountain
  vault`, and manages vaults and their secrets with `fountain vault`.
  Deleting an agent or an environment is the app's or the API's.
- The **manual** at `/docs` is public, searchable and covers the same
  topics as `priv/help`, which was a second, smaller and older copy.

Two copies of a configuration form drift. The console's agent form had
grown its own model suggestions, credential prompts and provider selects
that the app had to match. Two copies of the help drifted too: the topics
`fountain apply` and the secrets managers were documented in both places
with different details.

## Decision

1. **The console covers the dashboard, audit, API keys, account and admin.**
   `FountainWeb.AgentsLive.{Index,Form,Versions}`,
   `EnvironmentsLive.{Index,Form}` and `VaultsLive.{Index,Form}` are
   removed, with their routes, their sidebar links, their `g a` / `g e` /
   `g v` shortcuts and `FountainWeb.InferenceCredentialSave` (used only by
   the agent form). The old paths return the ordinary 404, as the other
   retired browser paths do (see `docs/concepts/surfaces.md`).
2. **Configuration lives in the Conversations app, the CLI and the API.**
   The contexts (`Fountain.Agents`, `Fountain.Environments`,
   `Fountain.Vaults`) and every `/api` route are unchanged. An agent's
   version history is readable with `GET /api/agents/:id/versions` and a
   vault secret's expiry with `fountain vault show` or the API.
3. **The browser avatar route goes.** `GET /agents/:id/avatar`
   (session-authenticated) was used only by the agent pages; nothing left
   in the console renders an avatar. `/api/agents/:id/avatar` stays.
4. **The dashboard drops its agent, environment and vault counts.** It
   keeps the month's usage, what is running now and the recent
   conversations, and links out to the Conversations app. With no app
   configured it points at the CLI and the API.
5. **In-app help is the manual.** `FountainWeb.HelpLive.Show`,
   `Fountain.Help` and `priv/help/*.md` were removed by #2721, which
   pointed the sidebar and `g h` at `/docs` and left `/help` a 404. This
   decision moves into `docs/` what `priv/help` had and the manual lacked
   (the manifest format and secret managers in a new `guides/manifests.md`
   page, the operator procedures into the operate guides, the sandbox
   notes into the `fountain` skill page), and makes `/help` redirect to
   `/docs` and `/help/:topic` to the page that took the topic
   (`FountainWeb.HelpRedirectController`, a static map); an unknown topic
   goes to `/docs`.
6. **The secret-expiry email links no page.** It names each vault and key,
   gives the `fountain vault set-secret` command that replaces the value,
   and names the API call that records the new expiry. The email itself
   was removed later the same day
   ([0011](0011-self-host-first-admin-bootstrap.md), mail addendum).

## Consequences

- **Rollback has no surface.** `Agents.rollback_agent/3` was called only by
  the versions page. It stays in the context, tested, but nothing reaches
  it: no API route, CLI command or app calls it. To go back to a version,
  write its `config` to the agent again (`PUT /api/agents/:id` or a
  manifest), which becomes the newest version. A rollback endpoint would be
  a new API decision.
  (`rollback_agent/3` itself was removed later the same day, #2733.)
- **0029 amended.** Its status lists the history page at
  `FountainWeb.AgentsLive.Versions`; that page is gone, and see the
  previous point for rollback. The rest stands.
- **0037 amended.** It lists `Fountain.Help` among what stays in
  `fountain`. It is removed, not moved.
- **A deployment with no Conversations app** configures agents,
  environments and vaults with the CLI, a manifest or the API.
- **Existing links.** Bookmarks and old emails that point at `/agents*`,
  `/environments*` or `/vaults*` get a 404; the retired-paths table in
  `docs/concepts/surfaces.md` names the destination for each. `/help`
  links keep working through the redirect.

## Alternatives considered

- **Keep read-only console pages.** Lists without forms still need the
  same queries, presenters and tests, for a view the app already has.
  Rejected.
- **Redirect the retired configuration paths to the app.** The
  conversation paths were redirected once and the redirects were removed
  (#2105); the app's URL is per deployment and may be empty. The same 404
  and a documented destination is simpler. Rejected.
- **Add a rollback endpoint now.** That is an API and SDK change with its
  own decision; nobody has asked for it outside the console. Deferred, not
  built.
- **Keep `/help` as a 404.** The redirect is one small controller and keeps
  links in old agent instructions working. Rejected.

## Addendum — 2026-10-15: Arugula is the human UI

Decided by the maintainer. Fountain's human UIs are two clients of the same
`/api`, neither of them part of this repository:

- **Arugula** ([arugula-salad/arugula](https://github.com/arugula-salad/arugula),
  tracked in [#942](https://github.com/arugula-salad/arugula/issues/942)), the
  primary one. As planned in that issue it signs in with the device grant,
  lists and follows conversations, and turns permission requests into
  cards; on this date those phases are not yet built. They land there, not
  here.
- **The Conversations app** (managoat/demos), kept as a second client.

Configuration of agents, environments and vaults is the API, `fountain
apply` and the other CLI commands, and those two clients, as far as each
has built it. Decision 2 above reads that way: the Conversations app is no
longer the only browser surface for it. The console's scope is unchanged.

The one Fountain change it needed so far: `POST /api/auth/device` takes an
optional `client_name`, which the approval page at `/device` shows as the
client's unverified claim and which names the minted API key in place of
`CLI login — <date>`. The CLI sends `fountain CLI on <hostname>`.
