### Upgrade notes

- **A sandbox's own token can no longer write agents, environments or
  vaults** (#2672). The `sprite`-scoped `FOUNTAIN_TOKEN` a conversation hands
  its sandbox now gets `403` with `reason: "insufficient_scope"` on create,
  update and delete of agents (and their avatars), environments, vaults and
  their secrets, on `POST /api/vaults/:id/copy`, `POST /api/apply` and
  `POST /api/conversations/:id/reapply`. Reads, and starting and prompting
  conversations, are unchanged. A script that configured Fountain from inside
  a sandbox must use a full-scope key from outside it. See
  [What a sandbox credential can do](https://managoat.com/docs/api#what-a-sandbox-credential-can-do).

### Changed

- The bundled `create-team` skill now writes the proposed roster as a
  `fountain apply` manifest for you to apply, instead of creating the agents
  itself (#2672).

### Security

- A prompt-injected agent in a hosted sandbox could point an agent at the
  owner's self-hosted runner with any `runtime_command`, then start it: a
  shell on the owner's machine (#2672). The configuration writes that made
  this possible now need a full-scope key. The reapply route's documented
  refusal of sandbox tokens is now enforced.
