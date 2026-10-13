### Changed

- **Terminate answers before the sandbox is destroyed** (#2561).
  `POST /api/conversations/{id}/terminate` used to wait for the provider to
  destroy the sandbox, up to 16 s. It now answers once the conversation is
  terminated and the sandbox is marked for teardown, and then destroys the
  sandbox. The marked sandbox takes no new work. A destroy that fails or never
  runs is finished by the reaper within five minutes, like any interrupted
  destroy. Account deletion and other internal callers still wait for the
  destroy.
