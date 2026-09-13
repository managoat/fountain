# Changelog

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
