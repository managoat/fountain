### Fixed

- A sandbox no longer fails to provision when the sprite is briefly
  unreachable during the clone (#2491). The clone now retries the same way
  every other provisioning step already does, but only when the sprite
  refused to start the command at all. A clone that started and failed
  partway is still returned on the first attempt, so a half-written directory
  is never cloned over.
