### Fixed

- **New conversations provision about 3–4 seconds faster** (#2499). The
  broker CA is added to a fresh sandbox's trust store directly instead of
  rebuilding the whole store (about 0.4 seconds instead of 2.4); the
  sandbox's config files, env file and CA install run at the same time
  instead of one after another; and the bundled skills are written without
  the reconciliation a fresh sandbox has nothing to reconcile, alongside the
  rest of provisioning.

### Added

- **`fountain.provision_step.stop.duration`**, a histogram of each named
  provisioning step (create, skills, callback key, sandbox URL, broker
  session, sandbox config, inference reserve, adapter), tagged by `step`
  (#2499). Each step's start and stop also reach the JSON log.
