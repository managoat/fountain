### Changed

- **The `fountain-fixture` runtime left the published API contract** (#1716).
  It is one configured account's test harness on one deployment, and it was in
  the `runtime` enum of five OpenAPI schemas and therefore in every generated
  SDK's type. The contract now names the five shipped runtimes. A deployment
  that sets `DEPLOYED_ACP_FIXTURE_USER_ID` still names it in the OpenAPI
  document that deployment serves, so nothing changes for the deployed
  deterministic suite. Keep that variable set while any fixture agent still
  exists, even after `DEPLOYED_ACP_FIXTURE_ENABLED` goes false: those agents
  are retained so their owner can edit and delete them.
