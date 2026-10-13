### Changed

- **A prompt to a parked conversation answers before the sandbox wakes**
  (#2561). `POST /api/conversations/{id}/prompts` used to wake the sandbox
  inside the request: 6–13 s for a cold one, and a `503` after 30 s at worst.
  It now answers `queued` once the checks that need no provider pass. Those
  cover credit, the account, the agent, a sandbox being reset, and room under
  the sandbox cap and the fleet ceiling. The wake then runs behind the response.
  A wake that fails after that is reported on the event stream and to webhooks
  as `conversation.wake.failed`, with its `reason` and whether sending the
  prompt again can succeed (`retryable`). The sandbox queue, launches and team
  runs still wait for the wake, because they act on its refusal.
