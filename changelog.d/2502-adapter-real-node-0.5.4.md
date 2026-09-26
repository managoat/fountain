### Fixed

- **Claude and Codex conversations start answering about a second sooner**
  (#2502). Every adapter start (a new conversation, a reattach, waking a
  parked sandbox) went through the sandbox's `node` shim, which took ~0.8 s
  to start. The adapter now runs on the Node binary its install recorded, and
  reaches its first protocol reply in 0.4–0.55 s instead of 0.9–1.6 s. This
  comes from `managoat_runtimes` 0.5.4.
