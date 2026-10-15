### Upgrade notes

- **Environment disk checkpoints are removed** (#2530). Every conversation's
  sandbox now runs the environment's packages, clones and setup script from
  scratch, which is what it already did: checkpoint creation was off by
  default, and a Sprites checkpoint cannot be restored into a new sandbox.
  `CHECKPOINT_CREATION_ENABLED` is no longer read; remove it from your
  configuration. `POST` and `PUT /api/environments` answer `422` with an
  error on `checkpoint_id` when a request sends that field, and a manifest
  spec carrying it is refused as an unsupported key. The
  `fountain_checkpoint_create_stop_duration` and
  `fountain_checkpoint_restore_stop_duration` metrics and the
  `checkpoint_restore` stage event are gone. The `environments.checkpoint_id`
  column stays until a later release drops it.
