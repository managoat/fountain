### Security

- **Attaching another agent's conversation to a sandbox needs a full-scope
  key, and only a claude and codex pair may share one** (#2525). A sandbox's
  own token (`FOUNTAIN_TOKEN`), or any key below full scope, can no longer put
  a conversation of a different agent onto a persistent sandbox with
  `sandbox_id`: `POST /api/conversations` answers
  `403 guest_attach_requires_full_scope` (`reason: "insufficient_scope"`). An
  agent could otherwise pair another agent with a machine with no person
  involved and leave files there that the machine's own agent loads. A guest
  already on a machine keeps it through a team rotation or a `channel_id`
  rotation. Guests are also limited to a claude agent and a codex agent
  together; gemini and opencode pairs are now refused with
  `422 sandbox_identity_mismatch`, as is a claude and codex pair on a machine
  where an agent of another runtime has run. See
  [a second agent on a machine](https://managoat.com/docs/concepts/sandboxes#a-second-agent-on-a-machine).
