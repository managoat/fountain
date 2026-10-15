### Upgrade notes

- **The team and team schedules are removed** (#2703, ADR 0074). Every
  `/api/team*` route, `/api/team/stream` and `/api/mcp/team/:conversation_id`
  now answers 404, and schedules stop firing. A long-lived agent is a
  conversation you keep the id of, or bind to a `channel_id` of your own and
  resume. A routine is your own scheduler calling
  `POST /api/conversations/:id/prompts`. Conversations bound to
  `fountain:team` stay as ordinary conversations, transcripts intact. The
  `team_schedules` table is dropped in a later release.
- **`TEAM_APP_URL` is no longer read** (#2703). Remove it from your
  configuration.

### Removed

- The team: its routes, SSE stream, roster presence, the `team.*` audit
  events, the console's Team link and the catalog's `apps.team` (#2703).
- Team schedules: the per-minute scheduler and the `schedules` job queue
  (#2703).
- The `fountain-team` MCP server that team conversations received, and the
  bundled `create-team` sandbox skill (#2703).
- The `Teammate` and `Schedule` kinds of `fountain apply`. The API refuses a
  manifest naming either with a 422, and the CLI reports them as unsupported
  kinds (#2703).
