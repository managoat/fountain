---
type: ADR
title: "The team and team schedules are removed"
description: "Managoat is invoked through its HTTP API (REST, SSE, SDK, CLI) and ACP; the team, team schedules and team MCP server are removed."
tags: [product, api, conversations, scheduling, cli, sdk]
status: stable
adr: "0074"
adr_status: "Accepted"
date: 2026-10-15
---

# 0074 — The team and team schedules are removed

**Status:** Accepted — 2026-10-15, by the maintainer (#2703). Built.

## Context

Managoat's invocation surface is its own HTTP API (REST and SSE, which the
TypeScript SDK and the `managoat` CLI wrap) plus ACP (`managoat acp`). The
team was a second product on top of it:

- **The team** (#810): a teammate was one conversation per agent, bound to the
  reserved channel `fountain:team`, with its own `/api/team*` routes, SSE
  stream, "fresh conversation on the same computer" verb, audit actions and
  roster presenter.
- **Team schedules** (#825): a cron expression and a prompt per teammate in
  `team_schedules`, ticked every minute by an Oban cron.
- **The team tools** (#851): an MCP server Managoat served back to every team
  conversation at `/api/mcp/team/:conversation_id`, plus the bundled
  `create-team` sandbox skill.
- **The apps around it**: `TEAM_APP_URL`, the console's Team link, the
  catalog's `apps.team`, and the `Teammate` and `Schedule` kinds of `apply`.

Production showed little use, as reported by the maintainer on 2026-10-15:
3 new team conversations in the previous 30 days, out of 588. All 9 of the
maintainer's enabled schedules had failed every run with
`:inference_source_changed` since about 2026-10-01, and nobody noticed. The
only schedules still running were two toy schedules on a demo account.

Nothing the team did needs a special mechanism. A long-lived agent is a
conversation the app keeps the id of, or one it binds to a `channel_id` of its
own (#774) and resumes. A routine is the app's own scheduler calling
`POST /api/conversations/:id/prompts` (`sendPrompt` in the SDK).

## Decision

1. **The team is removed**: `Fountain.Team`, every `/api/team*` route
   including the stream, the `team:<user_id>` PubSub topic and the team
   schemas. A removed route gets the ordinary unmatched-path 404.
2. **Team schedules are removed**, with their workers, cron entry, `schedules`
   Oban queue, schemas and the `team_schedules` table. Managoat runs no
   user-defined schedules.
3. **The team tools are removed.** `Conversations.McpServers` appends no
   Managoat-served list: a turn's `session/new` carries only the agent's own
   MCP servers. The bundled `create-team` skill is gone; `managoat` is the
   only bundled skill.
4. **The apps link goes.** `TEAM_APP_URL` is not read and `GET /api/catalog`
   returns `apps: {conversations}` only.
5. **`apply` has three kinds**: `Environment`, `Vault` and `Agent`. The API's
   `ManifestResource.kind` enum does not list `Teammate` or `Schedule`, so a
   manifest naming either is refused with a 422 before anything is written;
   the CLI reports them as unsupported before it sends anything.
6. **`channel_id` stays, and `fountain:team` is ordinary.** Binding a
   conversation to a channel and resuming it is a general feature (#774).
   Nothing treats `fountain:team` specially: such a conversation takes
   harness titles and resumes like any other.
7. **Existing data.** Conversations bound to `fountain:team` stay ordinary
   conversations with their transcripts, `channel_id` and titles; no
   migration touches them.
8. **The SDK** drops `client.team`, `TeamSchedules` and the team and schedule
   types, a breaking change shipped as a new major.

## Consequences

- Applications that used the team break: every `/api/team*` call answers 404.
  The demo applications that called it were removed or ported separately.
- Schedules have no replacement in Managoat. An application that wants a
  routine runs its own scheduler, consistent with
  [0055](0055-hosted-fountain-and-local-control-planes.md) declining to add
  scheduling features.
- The release verb is gone. `Termination.release_conversation/2` and the
  `policy: :keep` path of `Machine.detach/2` had one caller after
  [0073](0073-one-sandbox-per-conversation.md), the team's fresh-conversation
  verb, and were removed with the `conversation.released` audit event.
  `Machine.detach/2` is only the last-detach decision.
- Related ADRs no longer hold where they name the team:
  [0039](0039-sandbox-files-over-the-api.md) (team routes open to a sandbox
  token, `create-team` writing a roster), 0055 (triggers on the service side;
  team MCP callbacks, while the broker and the `managoat` skill's calls home
  still need reachable endpoints), [0057](0057-retire-public-compatibility-protocols.md)
  ("team tools" among preserved behaviour) and 0073 (team rotation; its
  migration's choice of the team conversation as keeper is history).
- Migrations that mention the team are history and are not edited.

## Alternatives considered

- **Keep the team and fix the schedules.** They had failed silently for two
  weeks, which says how much they were used; fixing them keeps a second
  product to maintain.
- **Keep the team routes as a thin wrapper over conversations.** Keeps the API
  surface, SDK namespace and docs for a feature with three new conversations
  a month.
- **Keep schedules as a generic conversation cron.** A new scheduling feature,
  which 0055 declined; an application's own scheduler is enough.
- **Drop `team_schedules` in the same release.** The previous release read it
  during a deploy; one release later cost nothing and matched how the other
  removals landed.

## History

- 2026-10-15 — Decided and built: the team, team schedules, team tools and the apps link removed (#2703, #2705).
- 2026-10-15 — SDK 9.0.0 without the team (#2707); `team_schedules` dropped a release later (#2706); the release verb and other leftovers removed (#2715).
