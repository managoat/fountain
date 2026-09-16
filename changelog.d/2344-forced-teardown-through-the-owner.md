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
  next housekeeping pass. A reap the computer's owner refuses — because
  another teardown of the same computer is already running — answers
  `503 sandbox_unavailable` with a `retry-after` instead of failing, and the
  admin panel says so rather than dropping the page.

- Closing an account records no `sandbox.destroyed` for any of the computers it
  tears down (#2344, ADR 0058). Those events are attributed to the account,
  which is gone moments later, so they would survive as anonymous rows
  describing the cascade; `account.deleted` already names the account and
  counts the computers. The teardown request for each one is still recorded.
  Only closing an account is silent this way: stopping the compute of a
  released or expired claimable principal keeps its rows, so each of its
  computers is still recorded as destroyed. Neither records a per-conversation
  event, which is unchanged.

- `sprites_destroyed`, in the `account.deleted` event and in the deletion API
  response, now counts the computers torn down rather than the provider
  deletions confirmed (#2344, ADR 0058). A computer whose provider refused the
  call is still counted; its row is marked finished either way, and the
  housekeeping pass reconciles what is left behind.

- The housekeeping worker counts a computer it could not reclaim separately
  from one it did (#2344, ADR 0058). `expired` keeps meaning "reclaimed", so a
  provider or lease outage that refuses every teardown no longer reports
  healthy reclamation; the refusals appear as `refused` in the same run log and
  metric. The per-run cap on provider deletions now covers both of the worker's
  passes rather than only the second, so reclaiming a large backlog still
  drains over several runs.
