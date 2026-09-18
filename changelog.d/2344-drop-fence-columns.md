### Upgrade notes

- **This release drops two columns from `sandboxes`: `reset_requested_at` and `teardown_requested_at`** (#2344). Every replica must already run a release that includes #2423, which stopped reading them, before this migration runs. A replica on an older release reads both columns and fails every sandbox query once they are gone. Upgrade in two steps, and let the first finish rolling. A rollback of the migration adds the columns back empty.
