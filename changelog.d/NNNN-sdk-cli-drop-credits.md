### Removed

- **The SDKs drop their credit handling** (#NNNN). The server stopped
  answering 402 in #2609, so each client removes its credit error and the
  billing surface it carried: TypeScript 7.0.0 (`InsufficientCreditsError`,
  `upgradeUrl`), Python 0.8.0 (`InsufficientCreditsError`, `upgrade_url`),
  Elixir 0.8.0 (`:insufficient_credits`, `Fountain.Error.upgrade_url(error)`) and
  Swift 0.23.0 (the credit error cases and `upgradeURL`, plus FountainKit's
  `AdminResource.setComped`/`grantCredits` and the `comped` and credit fields
  on `AdminUser` and `AuthMe`). A 402 from a proxy in front of the server is
  now each client's generic error. See
  https://managoat.com/docs/sdk#credit-error-removal.
- The CLI no longer appends `(upgrade: …)` to an error message (#NNNN).
