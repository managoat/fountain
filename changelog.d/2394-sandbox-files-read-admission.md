### Fixed

- **A files read no longer races a park or a destroy of the same sandbox**
  (#2394). The four sandbox file routes check the sandbox again under the
  machine's lock before they run. A sandbox that is being parked or destroyed
  returns `503 sandbox_unavailable` with a `Retry-After`. Before, the read ran
  against a machine that was going away. A read that started first finishes
  before the park or the destroy calls the provider.
