### Added

- Add a unified wire-generation command and cross-client propagation probes so optional conversation fields no longer require per-client field registration (#2233).

### Fixed

- Generate encoding support and public initializers for nested and referenced Swift conversation input models, including array and dictionary elements; preserve omission, explicit null and values inside nullable child inputs and shared response models (#2241).
