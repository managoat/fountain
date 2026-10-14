### Upgrade notes

- **`POST /api/conversations/{id}/reapply` is removed** (#2676). It answers
  `404`. A conversation keeps the agent, environment, vault, model override
  and `session_config` it was created with; start a new conversation to
  change them. A prompt's `session_config` still applies to that turn. The
  TypeScript SDK's `Conversation.reapply()` goes in its next major release.

### Removed

- Reapply (#2676, #1565, #2215): the endpoint, the
  `conversation.configuration_reapplied` audit event, the `configuration`
  stage event it published, and the `rebuild_required` and reapply-only
  `conversation_busy` answers. A conversation's skills are still reconciled
  with its agent's on every wake. The `inventory_sandbox_metadata` release
  task no longer reports build fingerprints, which only reapply read. See
  [Choose the model](https://managoat.com/docs/api#choose-the-model).
