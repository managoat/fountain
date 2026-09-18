### Fixed

- **A crashing adapter version check no longer reinstalls the adapter**
  (#2402). When the pinned ACP adapter's `--version` dies on a signal, sandbox
  setup checks once more and then fails with that exit code (for example
  139). Before, it ran `npm install -g` over the shared global prefix while
  other conversations could be running the adapter from it. A missing or
  outdated adapter is still installed. This comes from `managoat_runtimes`
  0.4.5.
