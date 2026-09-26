### Fixed

- **New Claude conversations provision about 10 seconds faster, and every
  Claude turn that starts a fresh adapter about 3 seconds faster** (#PRNUM).
  The Claude adapter now installs from a pinned manifest of its whole
  dependency tree, with every package checked against its sha512 integrity,
  instead of through npm: about 2–3 seconds on a new sandbox instead of about
  12. The check before each adapter start no longer runs the adapter twice.
  Existing sandboxes reinstall once, into a new versioned directory, the next
  time they wake or start a turn. This comes from `managoat_runtimes` 0.5.1.
