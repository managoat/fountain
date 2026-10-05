### Changed

- **Each write in a wake's config step is timed on its own** (#2557):
  `reattach_config_runtime`, `reattach_config_instructions`,
  `reattach_config_ca` and `reattach_config_env` on the
  `fountain.provision_step` histogram, next to the `reattach_config` total.
