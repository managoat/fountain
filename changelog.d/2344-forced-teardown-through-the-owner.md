### Changed

- A computer past its maximum lifetime is now destroyed in the same
  housekeeping pass that expires it, instead of being marked finished in one
  pass and collected in the next (#2344, ADR 0058). The pass that collects
  leftovers is still there, as the safety net for a destroy that could not
  finish rather than the way it normally happens.

- Deleting an agent, and reaping a computer from the admin panel, now record
  `sandbox.destroyed` on the audit trail beside the
  `sandbox.teardown_requested` that has always marked the intent (#2344,
  ADR 0058). Reaping a computer that has no conversation running on it also
  destroys it at the provider straight away, where it used to wait for the
  next housekeeping pass.

- Closing an account deliberately records no `sandbox.destroyed` for each of
  the computers it tears down (#2344, ADR 0058). Those events are attributed to
  the account, which is gone moments later, so they would survive as anonymous
  rows describing the cascade; `account.deleted` already names the account and
  counts the computers. The teardown request for each one is still recorded.

- `sprites_destroyed`, in the `account.deleted` event and in the deletion API
  response, now counts the computers torn down rather than the provider
  deletions confirmed (#2344, ADR 0058). A computer whose provider refused the
  call is still counted; its row is marked finished either way, and the
  housekeeping pass reconciles what is left behind.
