# Changelog

## 0.5.0

- Add `run_request(request, *, timeout=None, collect_events=False)` for API-shaped launch inputs without per-field keyword mappings (#2229).

## 0.4.0

### Breaking changes

- `team.comms_status()` is removed. Teammate email and phone (Team comms) is
  gone from the server: `GET /api/team/comms`, the
  `/api/team/:agent_id/contact` operations and the `contact` key on a
  teammate no longer exist. Nothing else moves.

## 0.3.1

- Forward `sandbox_api_access` from `Fountain.run()`. Explicit `"none"` keeps callback credentials out of a fresh ephemeral sandbox; omitting the option preserves a resumed channel's policy (#1711).

## 0.3.0

### Breaking changes

Replace `SubscriptionRequiredError` imports and `except` clauses with
`InsufficientCreditsError`. The old export is removed. Read `error.upgrade_url`
to offer the credit-purchase page; do not retry a 402 without adding credit.

For billing error handling, use Fountain v0.13.0 or newer.
[v0.13.0](https://github.com/managoat/fountain/releases/tag/v0.13.0) is the first
release containing the credit-only server contract (`c3349343`).
`insufficient_credits` and a generic HTTP 402 identify the credit gate.
`subscription_required` has no special mapping; it follows the HTTP status.
The response still exposes its original code and purchase URL.

## 0.2.1

- Classify `sandbox_unavailable` as `NotReadyError`, preserving the server's `Retry-After` delay for callers retrying a refused sandbox binding (#2049).

## 0.2.0

- Add `Conversation.reapply()` for `POST /api/conversations/{id}/reapply`: re-select a conversation's agent, environment and vault on the machine it is already running.

## 0.1.1

- Bound idle stream reads to five seconds so cancellation completes behind a silent proxy.
- Reconnect idle streams from the last complete event and skip status reads after cancellation.

## 0.1.0

- First Python SDK release.
- Run and resume agents, stream turns, and answer permission requests.
- Manage agents, environments, vaults, teammates, schedules, and connections.
