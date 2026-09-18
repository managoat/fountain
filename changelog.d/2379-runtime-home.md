### Fixed

- Changing a persistent agent's runtime now selects a separate computer for the new runtime instead of repeatedly refusing launches. The previous computer and its disk remain available when the agent returns to that runtime. Explicitly attaching to a computer built for another runtime still refuses and explains how to start fresh or reset it (#2379).

### Upgrade notes

- Quiesce conversation launches and wakes on old replicas during the runtime-home schema/application cutover, then resume those writers only on the new version. Older versions do not include runtime in home lookup. Rollback is refused once multiple runtime homes share an old identity; it does not delete a disk to fit the old constraint. Homes without retained runtime evidence remain intact but are not automatically selected (#2379).
