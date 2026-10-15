### Removed

- **The in-app `/help` pages** (#2721). The manual at `/docs` replaces them;
  the console's sidebar entry and the `g h` shortcut now open `/docs`.
- **`Fountain.Release.inventory_sandbox_metadata/0`** (#2721), the read-only
  sandbox-metadata inventory for the #2102 rollout, and the operator console
  calls `Fountain.SandboxSkills.upgrade_manifest/3` and `manifest_status/2`.
  A disk with an interrupted skill install keeps refusing reconciliation with
  `skill_installation_incomplete`; start a new conversation for a fresh
  sandbox.
- **The Feature status page** (#2721). Every feature is on for every account;
  the configuration reference says how to turn on the broker.
- **`node` on `reattach` stage events** (#2721). One node runs the instance.
