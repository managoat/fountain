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

**Status:** Accepted, 2026-10-15, by the maintainer (#2703). Built in the PR that
adds this ADR. Dropping the `team_schedules` table is a separate migration,
one release later. **Amends:** [0039](0039-sandbox-files-over-the-api.md),
[0055](0055-hosted-fountain-and-local-control-planes.md),
[0057](0057-retire-public-compatibility-protocols.md) and
[0073](0073-one-sandbox-per-conversation.md), as described under
Consequences.

## Context

Fountain's invocation surface is meant to be its own HTTP API (REST and SSE,
which the TypeScript SDK and the `fountain` CLI wrap) plus ACP
(`fountain acp`). The team was a second product on top of it:

- **The team** (#810). A teammate was one conversation per agent, bound to
  the reserved channel `fountain:team`. It had its own routes
  (`/api/team`, `/api/team/:agent_id` and its messages and conversations),
  its own SSE stream (`/api/team/stream`) with `team` and `schedule` signals,
  a "fresh conversation on the same computer" verb, its own audit actions
  (`team.*`) and a presenter for roster presence.
- **Team schedules** (#825). A cron expression and a prompt per teammate,
  stored in `team_schedules`, ticked every minute by an Oban cron
  (`TeamScheduler`) that enqueued runs on a `schedules` queue
  (`TeamScheduleRun`).
- **The team tools** (#851). An MCP server, `fountain-team`, that Fountain
  served back to every team conversation at `/api/mcp/team/:conversation_id`,
  plus the bundled `create-team` sandbox skill.
- **The apps around it.** `TEAM_APP_URL`, the console's Team link, the
  catalog's `apps.team`, and the `Teammate` and `Schedule` kinds of
  `fountain apply`.

Production showed little use, as reported by the maintainer on 2026-10-15.
Team conversations got 3 new rows in the 30 days before, out of 588 new
conversations. All 9 of the maintainer's enabled schedules had failed every
run with `:inference_source_changed` since about 2026-10-01, and nobody
noticed. The only schedules still running were two toy schedules on a demo
account.

Nothing the team did needs a special mechanism. A long-lived agent is a
conversation the app keeps the id of, or one it binds to a `channel_id` of
its own (#774) and resumes. A routine is the app's own scheduler calling
`POST /api/conversations/:id/prompts` (`sendPrompt` in the SDK).

## Decision

1. **The team is removed.** `Fountain.Team`, `TeamController`,
   `TeamJSON`, `FountainWeb.TeamPresenter`, every `/api/team*` route
   including `/api/team/stream`, the `team:<user_id>` PubSub topic and the
   `Teammate*` and `Team*Request`/`Response` schemas are gone. A request to
   a removed route gets the ordinary unmatched-path 404.
2. **Team schedules are removed.** `Fountain.Team.Schedule`,
   `Fountain.Team.Schedules`, `TeamScheduleController`,
   `Workers.TeamScheduler`, `Workers.TeamScheduleRun`, the per-minute cron
   entry, the `schedules` Oban queue and the `TeamSchedule*` schemas are
   gone. Fountain runs no user-defined schedules. The `team_schedules`
   table stays for one release, so the previous release can still read it
   during a deploy, and is then dropped.
3. **The team tools are removed.** `Fountain.Team.Mcp`,
   `TeamMcpController` and `POST /api/mcp/team/:conversation_id` are gone,
   and `Conversations.McpServers` no longer appends a Fountain-served list:
   a turn's `session/new` carries only the agent's own MCP servers. The
   bundled `create-team` skill is removed; `fountain` is the only bundled
   skill.
4. **The apps link goes.** `TEAM_APP_URL` is no longer read,
   `Fountain.Apps.team/0` is gone, and `GET /api/catalog` returns
   `apps: {conversations}` only. The console's Team link and dashboard card
   are removed.
5. **`fountain apply` has three kinds.** `Environment`, `Vault` and `Agent`.
   The API's `ManifestResource.kind` enum no longer lists `Teammate` or
   `Schedule`, so a manifest that names either is refused with a 422 before
   anything is written. The CLI reports them as unsupported kinds before it
   sends anything.
6. **`channel_id` stays, and `fountain:team` is ordinary.** Binding a
   conversation to a channel and resuming it is a general conversation
   feature (#774) and is unchanged. Nothing treats `fountain:team` specially
   any more: a conversation bound to it takes harness titles like any other
   (the team's title guard is gone), and a `channel_id: "fountain:team"`
   resume behaves exactly as any other channel does.
7. **Existing data.** Conversations bound to `fountain:team` stay what they
   are: ordinary conversations, with their transcripts, their `channel_id`
   and their titles. No migration touches them. Existing schedules stop
   firing when this release is deployed. Their rows go with the table.
8. **The SDK.** The TypeScript SDK drops `client.team`, `Team`,
   `TeamSchedules`, `MessageOptions`, `TeamEvent` and the team and schedule
   types. That is a breaking change, so it ships as a new major version, in
   its own release PR, as 8.0.0 did.

## Consequences

- **Applications that used the team break.** Every `/api/team*` call
  answers 404. The demo applications in `managoat/demos` that called it are
  being removed or ported separately, and this change should merge after
  (or together with) that one.
- **Schedules have no replacement in Fountain.** An application that wants
  a routine runs its own scheduler. This is deliberate: 0055 (decision 3)
  already declined to add scheduling features, and the only production
  schedules that worked were toys.
- **The release verb is removed.** `Termination.release_conversation/2`
  (end a conversation, keep its machine) and the `policy: :keep` path of
  `Machine.detach/2` had one caller after 0073: the team's fresh-conversation
  verb. This change left them in place, unreachable; #2715 removed them, with
  the server's `:release_conv` and the `conversation.released` audit event.
  `Machine.detach/2` is now only the last-detach decision.
- **0039 amended.** Its 2026-09-27 addendum said the team routes stay open
  to a sandbox token and that the `create-team` skill writes a roster as a
  manifest. Both are gone; the rest of the addendum stands.
- **0055 amended.** Decision 3 ("Schedules and other triggers") said
  triggers belong to Fountain's service side. Fountain now runs no
  user-defined triggers at all. Decision 4's "team MCP callbacks" no longer
  exist; the broker and the `fountain` skill's calls home still need
  reachable endpoints.
- **0057 amended.** The list of preserved behaviour named "team tools".
  There are none; the rest of the list stands.
- **0073 amended.** Its "team rotation" paragraph describes code that is
  gone. Its migration's choice of the team conversation as the keeper is
  history and is not changed.
- **Leftovers.** Comments that describe the team as history were trimmed
  where code changed. Migrations that mention the team are history and are
  not edited.

## Alternatives considered

- **Keep the team and fix the schedules.** The schedules had failed
  silently for two weeks with nobody noticing, which says how much they
  were used. Fixing them keeps a second product to maintain. Rejected.
- **Keep the team routes as a thin wrapper over conversations.** That keeps
  the API surface, the SDK namespace and the docs for a feature with three
  new conversations a month. Rejected.
- **Keep schedules as a generic conversation cron.** That is a new
  scheduling feature, which 0055 declined to add. An application's own
  scheduler is enough. Rejected.
- **Drop `team_schedules` in the same release.** The previous release reads
  it during a deploy. One release later costs nothing and matches how the
  other removals landed. Rejected.
