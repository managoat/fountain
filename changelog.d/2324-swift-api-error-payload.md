### Changed

- Swift SDK: `APIErrorBody` decodes the new generated `APIErrorPayload`, read
  from the contract's one `Error` schema, instead of declaring its own wire
  keys (#2324). Its published members keep their names and Optional types.
  `code` now stays the body's `error` when `error` is already a code and
  `reason` only narrows it, as the contract describes: `credential_set_is_default`,
  `sandbox_not_resettable` and `broker_unavailable` used to surface as their
  `reason` (`is_default`, `ephemeral` or the sandbox status, `timeout` and
  the like). The key-auth and scope
  refusals, whose `error` is a sentence, still report `reason` as the code.
  The new `APIErrorBody.reason` carries the body's `reason` as sent, and a
  new initializer overload takes it; the published initializer is unchanged.
