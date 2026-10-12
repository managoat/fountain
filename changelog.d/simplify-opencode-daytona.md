### Upgrade notes

- **The opencode runtime and the Daytona sandbox provider are removed**
  (#NNNN). An agent whose runtime is `opencode` still loads and shows, but a
  conversation on it is refused with 400 `unsupported runtime: opencode;
  change the agent's runtime` until you move it to `claude`, `codex`, `gemini`
  or `acp`. A migration moves agents pinned to `sandbox_provider: daytona` to
  the instance default and marks Daytona sandboxes that were still live as
  terminated; delete any machine left behind in Daytona's own console.
  `SANDBOX_PROVIDER=daytona` now refuses to boot, and `DAYTONA_API_KEY`,
  `DAYTONA_API_URL` and `DAYTONA_SNAPSHOT` are no longer read.

### Removed

- The `opencode` runtime and the `daytona` sandbox provider, from the API
  enums, the console, the configuration and the manual (#NNNN). Requests that
  name either are refused at validation. Responses still carry the old value on
  rows written before the removal, so `runtime` on agents and conversations and
  `provider` on sandboxes are now plain strings in the OpenAPI document.
- `422 permission_policy_unenforceable`, which only opencode could produce
  (#NNNN).
