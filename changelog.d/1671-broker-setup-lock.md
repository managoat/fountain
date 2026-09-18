### Fixed

- Shared sandbox wakes hold the broker setup lock through sudoers installation and Git configuration, preventing concurrent setup from colliding on those files (#1671).
