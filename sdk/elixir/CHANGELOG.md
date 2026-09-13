# Changelog

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
