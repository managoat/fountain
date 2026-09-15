### Upgrade notes

- **The OpenAPI document declares one error schema** (#2324). `Error` now
  describes every JSON error status, and `AuthError`, `ChangesetError`,
  `UnprocessableEntityError`, `CredentialSetDeletionError` and
  `BrokerUnavailableError` are gone from `/api/openapi.json`, as is the inline
  402 body on `POST /api/conversations`. No response body changed: `Error`
  gained the optional `message`, `reason`, `errors`, `upgrade_url`,
  `active_sandboxes` and `limit` the server already sent. A client generated
  from the document loses those five type names and gains the fields on
  `Error`; `errors` is no longer marked required on the fifteen 422s that
  declared `ChangesetError`, which those operations never guaranteed (they
  also refuse with a code). The 406 `NegotiationError` keeps its own shape.
