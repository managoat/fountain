### Added

- **A second agent of another runtime can share a persistent sandbox** (#2515).
  `POST /api/conversations` with `sandbox_id` now attaches a conversation of a
  different agent to another agent's persistent sandbox when both name the same
  environment and vault and the runtimes keep their files apart, such as a
  codex agent on a claude agent's home. Two agents of one runtime, and `acp`
  agents, are still refused with `422 sandbox_identity_mismatch`. The sandbox
  stays its own agent's, a guest's reapply answers `409 rebuild_required`
  (`field: "shared_sandbox"` while another conversation is on it, `"guest"`
  once it is alone), and each conversation redacts the other runtime's
  inference credentials. A claude home created before this release refuses a
  codex guest with `409 codex_inference_conflict` until it is reset. See
  [a second agent on a machine](https://managoat.com/docs/concepts/sandboxes#a-second-agent-on-a-machine).
