### Upgrade notes

- **This release drops two columns from `sandboxes`: `reset_requested_at` and `teardown_requested_at`** (#2344). Every replica must already run **v0.20.0**, which stopped reading them (#2423), before this migration runs. A replica on an older release reads both columns and fails every sandbox query once they are gone. Upgrade from an earlier release to v0.20.0 first, and let it finish rolling. A rollback of the migration adds the columns back empty.
