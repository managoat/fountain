### Upgrade notes

- **Take this release only on one replica that deploys with Recreate**
  (#2685, ADR 0058, ADR 0072). A machine's lease now names a process of the
  running boot, and a booting node clears every lease another boot left. Two
  nodes that overlap during a rolling deploy would each read the other's
  leases as dead.

### Changed

- A machine operation whose process dies no longer holds the machine until a
  lease runs out (#2685). The next operation on it starts at once, where it
  used to wait up to two minutes and answer `sandbox_unavailable` meanwhile.
- The provisioning ceiling fires at 30 minutes (#2685). It used to fire 90
  seconds later, to let the provision's lease lapse first.
