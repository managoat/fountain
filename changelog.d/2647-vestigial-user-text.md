### Fixed

- **Text that still described credits, quotas and removed ChatGPT
  subscriptions is corrected** (#2647). The starter agent's prompt no longer
  says turns are billed against a credit balance, and the suspension email
  no longer mentions one. The API descriptions of sending a prompt and of
  running a team schedule name the fleet ceiling (`fleet_full`) instead of
  credit and quota checks. The feature status page describes ChatGPT
  subscriptions as rebuilt in v0.22.0, and the admin activity page lists what
  it actually records.
