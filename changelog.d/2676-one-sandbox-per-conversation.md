### Upgrade notes

- **Every conversation now has a sandbox of its own** (#2676, ADR 0073). A
  migration keeps one live conversation on each sandbox that carried
  several: the Team conversation if there is one, else the one with the
  most recent turn. Every other live conversation on it is detached. Its
  transcript stays, its runtime session is cleared, and its next prompt
  provisions a fresh sandbox. Files those conversations shared with the
  kept one stay on the kept sandbox only. To rule out a replica of the
  previous release attaching a conversation during a rolling deploy, stop
  the old replicas first. The columns this release stops reading
  (`sandboxes.mode`, `runtime`, `codex_inference_source`, `codex_peer_homes`,
  `departed_conversations`, `agents.sandbox_mode`) are dropped in a later
  release.

### Removed

- **Persistent sandboxes ("homes")** (#2676). `sandbox_mode: "persistent"` on
  `POST /api/conversations` and on agents is refused with
  `422 persistent_sandbox_removed`. `"ephemeral"` is still accepted, and the
  response's `mode` and `sandbox_mode` always read `"ephemeral"` (deprecated).
- **Attaching a conversation to an existing sandbox** (#2676). A non-null
  `sandbox_id` on `POST /api/conversations` is refused with
  `422 sandbox_attach_unsupported`. A child conversation gets a sandbox of its
  own.
- **Sandbox reset** (#2676): `DELETE /api/sandboxes/:id`,
  `fountain sandbox reset`, `resetSandbox` in the TypeScript SDK and the
  admin "Retry reset".
- The CLI's `--sandbox-mode` and `--sandbox` flags, and the ACP `_meta` keys
  `sandboxMode` and `sandboxId` (#2676).
- The home checkpoint at park, and the `checkpoint` field on
  `GET /api/sandboxes/:id`. `CHECKPOINT_CREATION_ENABLED` now covers only
  environment checkpoints (#2676).
- The errors `409 sandbox_at_capacity`, `409 codex_inference_conflict`,
  `409 sandbox_mid_turn`, `422 sandbox_identity_mismatch`,
  `422 sandbox_runtime_mismatch`, `409 sandbox_not_attachable` and
  `422 sandbox_not_resettable` (#2676).

### Changed

- Starting a new conversation for a teammate now gives it a fresh sandbox,
  and the previous one is destroyed. It used to keep the same computer
  (#2676).
- The max-lifetime ceiling (`SANDBOX_MAX_LIFETIME_HOURS`) destroys every
  sandbox. It used to park persistent ones (#2676).
- Changing an agent's environment, rebinding a teammate, or deleting an
  environment, vault or agent no longer retires a sandbox (#2676).
