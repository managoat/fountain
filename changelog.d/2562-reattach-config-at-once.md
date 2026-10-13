### Changed

- **A wake writes the sandbox's config files at once** (#2562). Reattaching to
  a sandbox rewrote the runtime config, the agent's instructions, the env file
  and the broker CA one after another; it now writes them concurrently, as a
  fresh provision has since #2499. Each reattach step is timed on the
  `fountain.provision_step` histogram under a `reattach_` step name.
