### Changed

- **`POST /api/conversations/{id}/wake` answers before the sandbox is up**
  (#2584). It answers `waking` once the checks that need no sandbox pass, as a
  prompt to a parked conversation does, and wakes the sandbox after the
  response. A wake that then fails is reported as `conversation.wake.failed`.
