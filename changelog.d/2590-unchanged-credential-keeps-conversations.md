### Fixed

- Saving a provider credential that a set already holds no longer ends the
  conversations running on that set with `409 inference_source_changed`
  (#2590). A different value still replaces the credential and ends them.
