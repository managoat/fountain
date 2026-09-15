### Removed

- **Swift SDK: `AuthMe.onboardingState` is gone** (#2269), finishing #1393 in
  the last client that still carried it. The server dropped
  `users.onboarding_state` in v0.16.0 (ADR 0038, settling NC-6 from ADR 0007)
  and the TypeScript SDK dropped the field in its 1.17.0, so this property has
  decoded `nil` from every reachable server for two releases. Read
  `onboardingCompleted` instead; there is no replacement for a part-way step,
  because the server no longer records one. A server old enough to still send
  `onboarding_state` decodes fine — the key is simply ignored.

### Changed

- Swift SDK: `AuthMe` is generated from the contract rather than handwritten
  (#2269). Property names, types and optionality are unchanged, `role` and
  `email_verified` stay `Optional` although the contract requires both, and the
  model additionally conforms to `Identifiable`.
