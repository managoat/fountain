### Fixed

- A sandbox no longer fails to provision when the sprite is briefly
  unreachable during the clone (#2491). The clone now retries the same way
  every other provisioning step already does, but only for failures that
  prove no command was started — a clone that ran and failed is still
  returned on the first attempt, so a half-written directory is never cloned
  over.
