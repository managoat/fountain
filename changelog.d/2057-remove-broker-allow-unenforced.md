### Upgrade notes

- **`BROKER_ALLOW_UNENFORCED` is removed** (#2057). It let a brokered
  conversation run on a sandbox provider without a network policy, and no
  shipped provider lacks one since the self-hosted runner was removed
  (#2682). An operator who set `BROKER_ALLOW_UNENFORCED=true` can drop it:
  it is ignored, and nothing changes on Sprites or E2B.

### Removed

- The `BROKER_ALLOW_UNENFORCED` variable (#2057). A brokered launch on a
  provider without a network policy is always refused with
  `backend_lacks_network_policy`.
