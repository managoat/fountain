### Upgrade notes

- **A permission request no longer outlives its turn** (#PRNUM, #2676). An
  agent that answers `session/prompt` with the stop reason `waiting` now ends
  a `failed` turn, and the request it held is denied, as at any turn's end.
  Requests that are answered while the turn is running, and the `ask`,
  `auto_allow` and `auto_deny` verdicts, are unchanged. A request nobody
  answers is still denied after five minutes.

### Removed

- **Requests that outlive a turn** (#PRNUM, #2676), added in #1635. This is a
  breaking API change:
  - `GET /api/conversations/{id}` no longer returns `pending_requests`, and no
    conversation response carries it.
  - A turn no longer carries `waiting`.
  - `permission_policy` no longer accepts `ask_timeout`. A policy that names
    it is refused as an unknown verdict. `_meta.fountain.timeout` on a
    `session/request_permission` is ignored.
  - `POST /api/conversations/{id}/requests/{request_id}` no longer opens a
    resume turn, and no longer returns `400 conversation_busy` or
    `409 permission_answer_not_delivered`.
  - The `turn` stage event no longer carries `waiting`, `waiting_request_id`
    or `waiting_deadline`, and the `request` stage event no longer carries
    `detached_timeout_ms`.
