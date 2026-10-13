### Fixed

- A turn whose server was stopped by a deploy before its prompt reached the
  agent now runs again on reattach instead of ending `interrupted`, so the
  prompt is no longer lost (#2593). A turn that started more than 10 minutes
  earlier still ends `interrupted`.
