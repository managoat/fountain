### Fixed

- **The Claude adapter install writes about 105 MB less to a new sandbox's
  disk** (#PRNUM). Each package now unpacks as it downloads instead of after,
  with its integrity checked before the adapter can run. Installs also record
  their phase timings in the sandbox (`.install-timing`) for diagnosing slow
  ones. This comes from `managoat_runtimes` 0.5.2.
