# Changelog

## [0.6.0] - 2026-09-17

### Added

- `client_request_id` on every prompt the client sends, so a caller names its submission and reads that name back off the turn it opened instead of inferring the turn from turn order (#1406). `:client_request_id` on `Fountain.run/3` and on `Fountain.Conversation.send/3`, and the `client_request_id` key on a `Fountain.run_request/3` request. A channel resume repeats the value on the prompts route, which is the request that actually opens the turn. It is a correlation, not an idempotency key: the same value sent twice opens two turns.

## [0.5.1] - 2026-09-15

### Fixed

- Share conversation launch handling between the request API and the convenience helper. New channels follow turn one; resumed channels submit the prompt and images once before following the next turn (#2250).

## [0.5.0] - 2026-09-15

### Added

- `Fountain.run_request/3` forwards API-shaped conversation inputs independently of local execution options (#2230).

## [0.4.0] - 2026-09-13

### Breaking changes

- `comms_status/1` on `Fountain.Team` is removed. Teammate email and phone
  (Team comms) is gone from the server: `GET /api/team/comms`, the
  `/api/team/:agent_id/contact` operations and the `contact` key on a
  teammate no longer exist. Nothing else moves.

## [0.3.1] - 2026-09-13

- Forward `:sandbox_api_access` from `Fountain.run/3`. Explicit `"none"` keeps callback credentials out of a fresh ephemeral sandbox; omitting the option preserves a resumed channel's policy (#1711).

## [0.3.0] - 2026-09-13

### Breaking changes

Replace `%Fountain.Error{kind: :subscription_required}` patterns with
`%Fountain.Error{kind: :insufficient_credits}`. Read `Fountain.Error.upgrade_url(error)`
to offer the credit-purchase page; do not retry a 402 without adding credit.

For billing error handling, use Fountain v0.13.0 or newer.
[v0.13.0](https://github.com/managoat/fountain/releases/tag/v0.13.0) is the first
release containing the credit-only server contract (`c3349343`).
`insufficient_credits` and a generic HTTP 402 identify the credit gate.
`subscription_required` has no special mapping; it follows the HTTP status.
The response still exposes its original code and purchase URL.

## [0.2.1] - 2026-09-13

- Classify `sandbox_unavailable` as `:not_ready`, preserving the server's `Retry-After` delay for callers retrying a refused sandbox binding (#2049).

## [0.2.0] - 2026-09-10

- Add `Fountain.Conversation.reapply/2` for `POST /api/conversations/{id}/reapply`: re-select a conversation's agent, environment and vault on the machine it is already running.

## [0.1.0] - 2026-09-02

- Initial Elixir SDK release.
- Add immediate agent runs with broadcast event and text streams.
- Add reconnecting, cursor-aware SSE with automatic `Last-Event-ID` resume.
- Add resumable follow-ups, permissions, conversation history, and turn control.
- Add agents, environments, vaults, write-only secrets, teammates, schedules, connections, and connection providers.
- Add sandbox lifecycle, file listing/read, and repository diff operations.
- Add CLI-compatible configuration, verified TLS, structured errors, and raw request access.
