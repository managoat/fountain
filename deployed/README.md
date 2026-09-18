# Verify a deployed Fountain

This suite runs outside Fountain against a base URL. It requires Node 24 or
newer and no package install, Elixir application, database connection, or SDK
credential store. The initial `probe` profile checks authenticated identity,
catalog capabilities, liveness and database readiness. The `basic` profile
adds resource CRUD, validation errors, key revocation, tenant isolation, and
an independent check of the instance's advertised response schemas.

The `execution` profile verifies two real tool-using turns on a fresh
ephemeral or persistent sandbox. `streaming` adds incremental output, reconnect and replay
conformance to those same two turns. Integration, recovery and browser
profiles remain tracked in #1606. A passing probe does not prove
that conversations work, and selecting an unimplemented profile fails setup.

## Run

Point it at a deployment and read the verdict:

```bash
scripts/verify-deployment.sh https://fountain.example.com
scripts/verify-deployment.sh http://localhost:4000 probe
```

The script is ergonomics over `deployed/verify.mjs`, which composes the target
and prints the failing checks, the remaining-resource count and the evidence
directory. Credentials come from `FOUNTAIN_SUITE_KEY` and
`FOUNTAIN_SUITE_OTHER_KEY`; on macOS, a key that is not exported is read from
the keychain under an account naming the exact target, so a key stored for one
deployment is never offered to another. There is no unbound fallback: point it
somewhere nothing is stored for and it asks you to export the keys. Provision
the two accounts once per deployment; see
[below](#provision-test-accounts).

`probe`, `basic`, `execution`, `streaming` and `canary` run from here. The
`secrets`, `mcp`, `webhooks` and `schedules` profiles need receiver origins,
schedule windows or fixture settings that no flag supplies; write a target
file and use [the CLI](#the-underlying-cli) for those.

Use `verify.mjs` directly to change what the run declares:

```bash
node deployed/verify.mjs https://fountain.example.com --profile execution \
  --runtime codex --model openai/gpt-5.5 --sandbox e2b
```

`verify.mjs --help` lists the flags. It composes the profile list, limits and
execution timings through `lib/target.mjs`, the same module `ci.mjs` uses, so a
local verdict and a CI verdict mean the same thing. Plaintext HTTP is accepted
only for a loopback target. A deployment adapter, a provider matrix and a
rollout digest belong to an environment rather than a caller, so they stay in
`ci.mjs`; see [Run in CI](../docs/guides/operate/deploy.md#run-in-ci).

### The underlying CLI

`cli.mjs` takes a hand-authored target file, and is what to reach for when a
run needs a field the flags do not cover, or when replaying a cleanup manifest.
Copy `deployed/target.example.json` and set `base_url`. Each run requires a new
output directory; its parent must already exist.

```bash
node deployed/cli.mjs run --config /tmp/fountain-target.json --out /tmp/fountain-run-001
```

### Provision test accounts

The suite never creates its own accounts: it asserts through the same public
API a client uses, so its credentials come from outside. Every profile except
`probe` proves tenant isolation, which needs a second account whose resources
the first cannot see.

`POST /api/auth/register` is the public registration route and is subject to
`REGISTRATION_ENABLED`: with registration closed it answers 403
`registration_closed`, and administering the deployment does not bypass that.
So either provision these accounts while registration is open and close it
again afterwards, or reuse two accounts that already exist. Verification runs
need no registration setting at all — only the two keys.

On a deployment you administer, with registration open:

1. Register both accounts and verify their email addresses.

   ```bash
   curl -fsS -X POST "$BASE/api/auth/register" -H 'content-type: application/json' \
     -d '{"email":"suite@example.com","password":"..."}'
   ```

   Verification is what allows a key to be minted at all: `POST /api/auth/token`
   answers 403 `email_unverified` until the address is confirmed. Follow the
   emailed link, or post the emailed token to `POST /api/auth/verify`.

2. Exchange each password for a key, then mint the key the suite will use.

   ```bash
   curl -fsS -X POST "$BASE/api/auth/token" -H 'content-type: application/json' \
     -d '{"email":"suite@example.com","password":"..."}'
   curl -fsS -X POST "$BASE/api/auth/api-keys" -H "authorization: Bearer $TOKEN" \
     -H 'content-type: application/json' -d '{"name":"deployed suite"}'
   ```

   Keep the two accounts' keys in `FOUNTAIN_SUITE_KEY` and
   `FOUNTAIN_SUITE_OTHER_KEY`. The suite reads only the variables its target
   file names; it does not search your home directory and does not log a
   credential value.

   To let `verify.mjs` find them without exporting them, store each under an
   account naming the deployment it belongs to. A key is only ever offered to
   that exact origin, so one stored for production is never sent to a local
   instance or to anyone else's host:

   ```bash
   security add-generic-password -U -s fountain-deployed-suite \
     -a 'https://fountain.example.com|FOUNTAIN_SUITE_KEY' -w
   ```

3. Give the primary account a way to pay for its turns. On a deployment with
   credits enabled, comp it: `POST /api/admin/users/:id/comp` as an
   administrator. Otherwise give it credits, or configure its own inference
   keys, as any other account would.

4. Check what onboarding created. A verification link lands in the browser at
   `/start`, which provisions a `starter` agent and mints a second, live API
   key labelled `quickstart`. Revoke that key: the suite does not use it, and
   it is a standing credential on an account whose keys otherwise live in a
   secret store. Posting the token to `POST /api/auth/verify` instead skips
   both.

`secrets`, `mcp` and `webhooks` additionally need Connections enabled on both
accounts; an account may be brokered and still have `connections_enabled`
false, which fails those profiles at setup.

Removing a suite account afterwards removes its fixtures with it. Keep the
accounts if you intend to verify this deployment again.

The default expected wire contract is `sdk/contract/contract.json` from the
suite checkout. Pin the checkout to the release you intend to verify, or set
`contract` to another versioned projection file, relative to the target file.
The result records its SHA-256. This is a structural validator for Fountain's
version-1 projection: primitive types, required fields, nullable fields, enums,
arrays, references, unions and additional-property rules. It does not claim
full OpenAPI validation of formats, numeric bounds or string patterns. It
permits compatible added fields unless the contract explicitly forbids them.

`required_capabilities` names runtimes and sandbox providers the deployment
must advertise. Declare these from your intended configuration, independently
of discovery. A required provider disappearing fails setup. An optional entry
has a `name` and `reason`; an absent optional capability is recorded as skipped.
No configured sandbox is needed for `probe`.

```json
{
  "required_capabilities": { "runtimes": ["claude"], "sandbox_providers": [] },
  "optional_capabilities": {
    "sandbox_providers": [{ "name": "sprites", "reason": "Not configured on this local fixture" }]
  }
}
```

## Results and limits

For a real conversation, use two verified accounts and configure inference
credentials on the primary account outside the suite. Select `execution` and
pin its runtime, model and sandbox provider explicitly. This profile creates
its own empty environment and agent and never attaches to an existing sandbox.

```json
{
  "base_url": "https://your-fountain.example",
  "credentials": {
    "primary": "FOUNTAIN_SUITE_KEY",
    "secondary": "FOUNTAIN_SUITE_OTHER_KEY"
  },
  "profiles": ["execution"],
  "execution": {
    "runtime": "claude",
    "model": "anthropic/claude-haiku-4-5",
    "sandbox_provider": "sprites",
    "provision_ms": 120000,
    "turn_ms": 90000,
    "max_turns": 2
  },
  "limits": { "request_ms": 30000, "run_ms": 330000, "cleanup_ms": 90000, "resources": 5 }
}
```

Execution observes provisioning through real SSE, writes a random nonce file
in turn one, reads it in a follow-up, and checks the bytes through the sandbox
file API. Both turns must have durable completion records and persisted tool
activity. It checks the second tenant cannot read the conversation, events,
stream or file, or interrupt/terminate the conversation. It then verifies
terminal conversation/sandbox state before cleanup deletes the transcript and
parent fixtures. Usage and IDs remain in the report after deletion.

Set `execution.sandbox_mode` to `persistent` to check a dedicated home.
The default remains `ephemeral`. A persistent run verifies that conversation
termination retains the home and exact artifact bytes. Cleanup then resets
the home through `DELETE /api/sandboxes/:id` and verifies its terminal state
before deleting the conversation, environment and agent. The manifest records
the mode before creation. An older manifest without a mode permits only
ephemeral cleanup. All homes belong to an agent and environment created by
that run; an existing sandbox cannot be attached to a suite conversation.

The fixture manifest records each prompt attempt **before** sending it. A
lost reply still consumes the two-attempt budget; prompts are never retried
automatically. Provisioning, each turn, the overall run, and cleanup have
separate deadlines. A stream that ends early fails the execution check;
use the `streaming` profile for intentional reconnect/replay assertions. SSE traces record
redacted frames with receive times, and a closed consumer releases its HTTP
connection. Each stream is capped at 4 MiB.

To verify ingress and replay, select `"profiles": ["streaming"]` with the same
explicit execution settings. It includes execution; selecting both is an
error. During turn one, the suite observes output and confirms that the
durable turn record is still running. It then closes the stream, waits for
at least one new persisted event, and reconnects with `Last-Event-ID`.

After turn two, it drains history with a three-event page size and compares
the live/reconnected events and two `wait=false` replay streams against a
fixed durable event prefix. IDs must increase without duplicates; they need
not be consecutive. Matching IDs with different payloads still fail. Events
newer than the completed-turn cursor may arrive while the checks run and do
not change that prefix. The report records the reconnect/missed-event IDs,
comparison counts and pagination evidence. Controlled idle-heartbeat timing
can be added with the deterministic fixture in #1611.

For `basic`, supply two **different** verified test accounts through explicit
environment-variable names. Two keys for the same account fail before any
fixture mutation. This profile includes the probe checks, so select `basic`
alone. Neither account needs inference credentials or a sandbox provider.

```json
{
  "base_url": "http://localhost:4000",
  "credentials": {
    "primary": "FOUNTAIN_SUITE_KEY",
    "secondary": "FOUNTAIN_SUITE_OTHER_KEY"
  },
  "profiles": ["basic"]
}
```

Basic creates an environment, vault, agent, and disposable API key. It verifies
read/update/list/delete behavior, field errors, missing resources, and denied
cross-tenant reads and mutations. The agent uses the built-in Claude runtime
with a model identifier accepted by the API; it is never started. A metadata
update keeps the run-owned name stable for interrupted-run recovery.

Actual responses always validate against the pinned contract. A separate
check compares the advertised operations, statuses and response schema shapes
for the exercised API surface, permitting compatible added properties. It
does not fetch the advertised schema to redefine the expected responses.
Schema failures stay failures; there is no blanket bypass for the broader
schema gaps tracked in #1432 and #1444. The OpenAPI document is summarized by
hash/version rather than copied into response traces. Collection responses
are checked in memory but omitted from traces so existing account resources
and the second tenant's resources do not become suite artifacts.

Every initialized run writes `result.json` and `junit.xml`, with check durations
and failures. `http.jsonl` contains bounded JSON response evidence and request
IDs; headers carrying credentials and request bodies are not recorded. Known
credentials and secret-shaped response fields are redacted. Non-JSON bodies
are rejected without recording their raw contents. Output directories are
private and new artifact files use mode `0600`.

| Exit | Meaning |
|---|---|
| 0 | Every required check passed; cleanup completed |
| 1 | Assertion, run deadline, or runtime failure |
| 2 | Invalid configuration, missing credentials, identity/capability setup failure |
| 3 | Cleanup failed or a creation intent remains unresolved |
| 130 | Interrupted; inspect the report and cleanup manifest |

Checks and fixture creation are sequential. `limits` bounds request duration
(including response bodies), the overall run, the separate cleanup window,
and the number of created resources. HTTP responses are capped at 2 MiB and
redirects are not followed. SIGINT/SIGTERM cancel requests and then allow the
bounded cleanup pass. SIGKILL cannot run cleanup.

`probe` and `basic` invoke **zero inference turns**. `execution` submits at
most two prompts and records provider-reported usage. It does not enforce a
monetary cap: prompt count and client deadlines are bounded, but model/tool
activity inside a turn and provider charges are not a fixed price. Cleanup
terminates the conversation after failure or cancellation; an unavailable
server/provider can prevent that, which leaves a visible cleanup failure.

By default, deployment identity is unverified. The optional Kubernetes adapter
checks the intended runtime image digest across every serving pod before and
after the public suite. Reports record the suite checkout revision separately.
See the [operating guide](../docs/guides/operate/deploy.md#verify-the-deployed-instance)
for CI environments, rollout hooks, scheduled canaries, fixture provisioning
and failure ownership. Public profiles need no cluster credentials.

## Interrupted runs and cleanup

`cleanup.json` binds run-owned fixtures to the normalized target URL, verified
account ID and a random run ID. A creation intent is saved before its POST;
the returned ID is saved before contract assertions. Cleanup uses only the
supported resource kinds and verifies the exact run-owned name before deletion.
It never deletes an account or discovers resources by a broad name prefix.

```bash
node deployed/cli.mjs cleanup --config /tmp/fountain-target.json \
  --manifest /tmp/fountain-run-001/cleanup.json --out /tmp/fountain-cleanup-001
```

For a normal run or a matrix, replay all manifests from its results directory:

```bash
node deployed/cleanup-replay.mjs --config /tmp/fountain-target.json \
  --results /tmp/fountain-run-001 --out /tmp/fountain-cleanup-batch-001
```

The output directory must be new and outside the source results. Replay checks
up to seventeen manifests, continues after a failed manifest, and records each
outcome in `replay.json`. After two minutes, replay attempts no more manifests;
the current runner retains its separate cleanup deadline. Any failed or
unattempted manifest keeps the batch nonzero. Keep the original target file,
credentials and receiver sidecars with the manifests for recovery.

SIGINT, SIGTERM and the admission deadline immediately record a stop reason and
mark the active entry `interrupted`. The active cleanup retains its own deadline;
later entries remain `not_run`. If cleanup finishes, its final result replaces
the interrupted entry, but the batch remains unsuccessful. A forced process
kill can still prevent completion; an interrupted entry is not proof of cleanup.

In CI, verification has a 52-minute step timeout within a 75-minute job.
After a failed or interrupted suite step, the workflow uploads the original
evidence, then starts a fresh cleanup process with a six-minute step timeout.
Replay admits work for two minutes; a CI manifest can then need its 90-second
fixture cleanup and a separate 90-second receiver cleanup. The six-minute cap
leaves another minute for process and evidence overhead. Setup, monitors and both
artifact uploads have explicit step limits; all step limits total 71 minutes,
leaving four minutes of job overhead. Increasing the job limit does not increase
the verification step or inference budgets.
It uploads updated manifests and replay evidence under a separate
`deployed-cleanup-...` artifact, preserving the original `deployed-...` artifact.
A successful retry does not change the failed verification verdict.
CI passes `--allow-empty`: a setup failure before any manifest was written
produces a successful replay step with `status: "no_manifests"` and no API calls,
even when the target file or results directory was never created. This records
that no cleanup was attempted. Invalid evidence still fails; manual replay
without this flag rejects missing or empty results.
[GitHub cancellation](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation)
can terminate the job before these final steps finish. A hard job timeout or
runner loss can prevent upload and replay. This step cannot recover journals
lost with the runner. Use the [runner-loss recovery procedure](runner-loss-recovery.md)
from a separate machine/process: replay copied evidence when available, or
reconstruct a bounded, reviewed cleanup manifest with `recover-fixtures.mjs`
when both the original journal and uploaded artifact are gone. The procedure
covers exact ownership, interrupted creates, repeated recovery, supported
profiles, escalation, and the recorded deployed exercise.

For missing evidence, start with read-only discovery on the recovery machine:

```bash
node deployed/recover-fixtures.mjs inventory --base-url https://fountain.example.com \
  --owner-id "$SUITE_ACCOUNT_ID" --run-id "$SUITE_RUN_ID" --out /tmp/recovery-inventory
node deployed/recover-fixtures.mjs reconstruct --base-url https://fountain.example.com \
  --evidence /tmp/recovery-inventory/evidence.json --out /tmp/recovery-reconstructed
```

Between those commands, corroborate exact ownership, stop writers and fill the
candidate's evidence notes with every submitted create intent. Use the dedicated
`FOUNTAIN_SUITE_KEY` or the exact origin's suite keychain entry. Reconstruction
supports basic/execution/streaming/deterministic fixtures, at most 100 intents,
and makes no mutations; unsupported profiles or ambiguous ownership require
operator escalation. Replay its reviewed `cleanup.json` with the ordinary
cleanup command above and its generated `cleanup-target.json`, then repeat.
The [deployed exercise](evidence/1697-runner-loss-2026-09-17.md) recovered a
lost journal and create response with zero remaining fixtures and zero inference.

Use the same target and account. Cleanup has its own deadline, tolerates
already deleted resources, and runs in reverse creation order. A lost create
response can be reconciled by an exact unique name. When an intent has no
visible match, it remains unresolved: the original request may still commit.
Retry cleanup after the server settles and investigate a persistently
unresolved intent; absence at one instant is not proof of successful cleanup.

The runner supports named agent, environment, vault and API-key fixtures,
plus ephemeral conversations linked to its own recorded agent/environment.
Conversation ownership is checked using the run-specific channel ID and both
parent IDs. Cleanup verifies that the sandbox is terminal before deleting the
conversation; it does not use the persistent-sandbox reset endpoint. A failed
conversation cleanup retains its parent fixtures so ownership evidence is not
lost. Keep manifests until every entry is cleaned. A cleanup failure stays
visible even when the assertions themselves passed.

## Develop the suite

```bash
node --test deployed/test/*.test.mjs
```

These tests use loopback HTTP servers to exercise harness failures; they are
not evidence that a deployed Fountain conforms. Live verification runs the
CLI against a released image or an explicitly configured remote test instance.
The normal CI checks run the harness tests without live credentials.

Add profiles as ordinary modules using `ctx.check`, `ctx.client`, and
`ctx.fixtures`, with assertions against public responses. Register them in
`lib/runner.mjs`. Mutations must record cleanup intent before sending a create
request. Do not inject database rows, import server factories, or substitute
an in-process Fountain for a deployed verdict. Existing SDK conformance
remains separate and runnable with its existing commands.

## Console browser profile

The independent [console browser profile](browser/README.md) covers sign-in,
agent editing, API key lifecycle and credential-form validation. Its optional
pinned Conversations journey submits two artifact prompts through the app.
Remaining live verification, credential setup and first-account bootstrap work
is tracked in #1618.

## Provider and runtime matrix

`deployed/matrix.mjs` applies the same execution scenario to an explicit,
versioned set of combinations. Copy `deployed/matrix.example.json` and adapt
it to your target before enabling it. The example expects Codex on a dedicated
runner in both sandbox modes. Its other catalog entries are documented gaps,
not evidence that those combinations work.

```bash
node deployed/matrix.mjs \
  --config /tmp/fountain-target.json \
  --matrix /tmp/fountain-matrix.json \
  --subset canary \
  --out /tmp/fountain-matrix-001
```

Each cell pins its runtime, canonical model, sandbox provider and mode.
A supported cell declares execution, artifact, follow-up, tenant isolation
and lifecycle capabilities. Add `streaming` to select the existing replay
scenario for that cell. A gap has a concrete reason and a Fountain issue
link. Every runtime/provider pair named by the matrix must declare both
modes, using gap cells where needed. `catalog_gaps` accounts for advertised
runtimes or providers outside those axes. Render remains linked to #1439;
its verification ladder must finish before the runner accepts a Render cell.

`canary` selects at most two supported cells. `scheduled` contains that subset
and `full` contains every supported cell. The broader subsets permit at most
16 cells. Each cell authorizes two prompts, creates three resources, and runs
alone. `limits.max_turns` authorizes the total prompt ceiling, up to 32;
`limits.run_ms` bounds the matrix to at most 50 minutes. A deadline or signal
stops new cells while the current cell retains its separate cleanup deadline.
Prompts are not retried. These budgets bound attempts and time, not a currency
amount; choose models and provider quotas for the intended spend.

Before creating any sandbox, the suite validates every selected configuration
and both key variables. A public probe then checks every required capability
from all supported cells, including cells outside the selected subset. A
required provider disappearing fails the run. An advertised capability with
no matrix axis or documented catalog gap also fails. Discovery never removes
cells from the declared plan.

Each cell has its own `result.json`, JUnit file, HTTP/SSE traces and durable
cleanup manifest. The root result records the matrix SHA-256, suite revision,
per-cell status, prompt attempts, usage, lifecycle and deployment evidence.
An assertion failure does not hide later cells. A cleanup failure stops new
cells and records them as not run; the overall result remains unsuccessful.
Resume cleanup with the ordinary cleanup command and that cell's manifest.
Use the same target and credentials. Temporary generated configuration files
are removed after the matrix finishes.

Public conversation responses currently expose the agent configuration
version and runner information, but no installed runtime binary version or
immutable sandbox image reference. Reports retain the available information
and explicitly record those missing fields. A configured deployment observer
still verifies the Fountain release image for every cell. It does not establish
the sandbox image or runtime package version. Full runtime/image provenance
remains a limitation of #1613 until an authoritative surface exposes it.

For CI, set environment variable `SUITE_MATRIX_JSON` to the reviewed matrix
and select `matrix-canary`, `matrix-scheduled` or `matrix-full` in the existing
workflow. `matrix-canary` with rollout mode verifies the declared minimal
subset after an image rollout. The existing basic/execution canary remains
available. A separate weekly schedule at 04:43 UTC Saturday uses
`matrix-scheduled`; it runs only when repository variable
`DEPLOYED_MATRIX_ENABLED=true`. It shares target concurrency with all other
deployed runs. Configure its distinct `SUITE_MATRIX_MONITOR_URL` secret before
enabling the weekly schedule. A missing weekly monitor does not fall back to
the frequent canary monitor. The workflow retains all per-cell artifacts.

The matrix implementation and local lifecycle tests do not establish hosted
provider support. Retain each target's first released-deployment matrix result
before changing a configured gap into a supported cell.

## Secrets and brokered egress

The opt-in `secrets` profile checks #1614 with four random synthetic values.
It creates its own environment, vault, binding, agent and ephemeral conversation
through public APIs. Two colliding secret names exercise vault precedence.
The bound value must reach the sandbox as a placeholder; the unbound value
must reach it in the clear. One tool-using prompt runs a bounded Python/curl
script against a controlled HTTPS receiver. No real service credential is
used for the fixture requests.

The receiver must independently observe the vault's bound value in the
broker-injected `X-Fountain-Fixture` header, the vault's unbound value in the
request body, and the placeholder in the sandbox-visible environment. It
returns both matching synthetic values so the script can echo them into the
conversation. The durable transcript must retain the receiver's independent
receipt ID and both `[REDACTED]` values. Raw HTTP and SSE responses are checked
before harness redaction; the harness cannot hide a server disclosure and
report success. File-response inspection also checks decoded base64 content.
An artifact scan fails and scrubs any known synthetic value left on disk.

The same script attempts a second controlled hostname excluded from the
network policy. It must receive a CONNECT 403 with curl exit 56. The public
egress log must record both the successful credential attachment and that
denial, and the receiver must observe no blocked-host request. Cross-tenant
secret reads/writes/deletes and binding access are checked separately. This
checks the documented broker contract; it does not prove the provider's
network floor survives a wake or implement #1555.

### Configure the controlled receiver

Run the exact `deployed/receivers/secrets.mjs` file from the suite checkout on
a dedicated service. Route two distinct HTTPS hostnames to that same singleton
process. Do not spread them across independent replicas: state is in memory,
and a restart loses active runs and causes their checks to fail. The suite
checks both hosts' protocol version and receiver instance ID before creating
Fountain resources. Both hosts must be publicly reachable from the suite and
the allowed one from the sandbox through the broker.

Set `FOUNTAIN_RECEIVER_ADMIN_KEY` to a generated credential of at least 32
characters, supplied through a secret store. It controls run registration,
receipt inspection and deletion. It never enters Fountain or the sandbox.
For TLS in the Node process, set `TLS_CERT_FILE` and `TLS_KEY_FILE`. When a
managed HTTPS ingress terminates TLS instead, explicitly set
`RECEIVER_TLS_AT_INGRESS=true`. Plain HTTP is not accepted in target URLs.
Set `PORT` if the backend should use a port other than 8080, then start it.

```bash
node deployed/receivers/secrets.mjs
```

The receiver has no request logging or disk state. It stores expected
fingerprints and observed match booleans, timestamps and receipt IDs. It echoes
only matching values with the suite's synthetic format. It rejects unknown
runs, wrong nonces and mismatched credentials. A run lasts at most 15 minutes,
accepts at most eight capture requests, and the process holds at most 32 runs.
Request bodies are capped at 16 KiB. Expired runs disappear on the next
request. Receiver state also gets an explicit delete on normal suite exits.
Keep ingress access logs free of request bodies, authentication headers and
response bodies.

### Configure and run the profile

Copy `deployed/secrets.example.json` and set the actual Fountain and receiver
URLs, runtime/model and provider. Both dedicated tenants must have broker and
Connections access. The primary tenant also needs its usual inference
credentials. Select an ephemeral Sprites, E2B or Daytona sandbox. A runner is
rejected because it does not enforce broker egress. The sandbox image must
provide Python 3 and curl; runtime setup must also have its usual dependencies.

`bootstrap_hosts` explicitly permits the package hosts needed for runtime
installation, such as `registry.npmjs.org`. Review this list for the configured
image/runtime; there is no wildcard or implicit list. The blocked receiver
cannot be on it. The fixture's credential binding names only the allowed
receiver, and the script targets only the two controlled URLs. Existing
inference bindings continue to support the selected runtime.

```bash
node deployed/cli.mjs run \
  --config /tmp/fountain-secrets.json \
  --out /tmp/fountain-secrets-001
```

The prompt budget is explicitly one, with no automatic retry. The run limit
cannot exceed ten minutes, within the receiver's retention window. Missing
broker/Connections access or unreachable/mismatched receiver hosts fail setup
before fixture creation. Provisioning/broker setup failures remain failures
with their category recorded, and each later assertion has its own named check.
Receiver observations are retained even when the turn fails. A healthy model
answer without the expected receiver and public egress evidence cannot pass.

Cleanup terminates the conversation before deleting its agent, binding, vault
and environment. A failed conversation cleanup retains its parent resources
and bindings. Leaking API responses still fail the verdict, but cleanup can
read their ownership evidence and remove the fixture. `cleanup.json` records
binding names/hosts and attached vault ownership; `receiver.json` records the
remote run and expiry without its admin credential. Lost create replies retain
cleanup intent. The ordinary cleanup command with the original target file
also retries receiver cleanup after Fountain cleanup. An operator can inspect
these manifests when a process is killed before its cleanup runs.

The existing workflow accepts `profile: secrets` for manual public or rollout
verification. Add the receiver settings to the approved environment's
`SUITE_TARGET_JSON` and its admin key as environment secret
`FOUNTAIN_RECEIVER_ADMIN_KEY`. This profile is separate from frequent and
matrix canaries; no schedule enables it automatically. Retain a successful
released-deployment result before considering #1614 verified. Local receiver,
proxy-wire and API-fixture checks cover narrower boundaries and do not replace
that result.

## Authenticated MCP tools

The opt-in `mcp` profile covers #1615 with a controlled Streamable HTTP tool
server. It creates an environment secret and an agent through public APIs.
The stored agent header contains a `${SUITE_MCP_...}` reference. Fountain
resolves that reference for the runtime. The bearer value is random, synthetic,
and valid only for this receiver run.

This mode tests static bearer delivery. Its permitted identity is the fixture's
per-run principal. It does not establish a Fountain conversation identity or
test callback-token rotation. Conversation authentication for Claude, Codex,
Gemini and OpenCode remains an explicit linked gap under
[#1405](https://github.com/managoat/fountain/issues/1405).
Each result lists the selected runtime as required and the other runtimes as
not run. A selected runtime that cannot authenticate or discover the tools
fails; it is never silently skipped.

Run `deployed/receivers/mcp.mjs` from the same suite checkout on one controlled
HTTPS origin. Route it to one process, with request/header logging disabled.
Provide `FOUNTAIN_MCP_ADMIN_KEY` with at least 32 random characters. Either set
`TLS_CERT_FILE` and `TLS_KEY_FILE`, or explicitly set
`RECEIVER_TLS_AT_INGRESS=true` behind HTTPS ingress. The default port is 8080.
The admin key stays in the suite and receiver; it never enters the sandbox.
The receiver stores only credential hashes, nonces, session IDs, receipt IDs,
and allow/deny observations in memory. Runs expire after 15 minutes. Each run
allows at most 96 requests, eight active sessions and eight tool attempts;
request bodies are limited to 16 KiB. All browser origins are rejected.

The receiver implements the [MCP 2025-03-26 Streamable HTTP lifecycle](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
with JSON responses, initialization, session IDs, tool listing, tool calls and
session deletion. It negotiates that protocol version with newer clients.
It has no server-initiated stream, batch requests, OAuth, stdio or legacy SSE
transport. It is a bounded suite fixture, not a general MCP service.

Copy `deployed/mcp.example.json`, set the actual Fountain and receiver origins,
and pin the runtime, model and sandbox provider. The dedicated primary account
needs inference credentials. The second account must be distinct and verified.
The receiver must be reachable from both the suite and sandbox. Runner targets
also require their runner to be online. Authorize exactly two prompts, an
ephemeral sandbox, at least three resources and at most a ten-minute run.

```bash
node deployed/cli.mjs run \
  --config /tmp/fountain-mcp.json \
  --out /tmp/fountain-mcp-001
```

The first prompt calls `suite_nonce` and `suite_denied`; the latter returns a
controlled tool error. The second prompt calls `suite_nonce` with a fresh nonce.
Each call must have a receiver-observed permitted principal, preceding tool
discovery, and a generated receipt paired with its tool-use ID in both live
SSE and durable history. The denied tool result must carry an error flag.
Model text alone cannot pass these assertions. A wrong-credential setup probe
must get 401, and any additional rejected runtime credentials fail the result.
The suite never makes an accepted MCP discovery or tool request itself.

Raw Fountain HTTP/SSE responses are checked for credential disclosure before
artifact redaction. The report retains receiver observations, runtime coverage,
turn IDs, usage and failure categories. Configuration, provisioning, receiver
connectivity, runtime discovery, and tool/event failures remain distinguishable.
Failures retain the independent receiver evidence when it is reachable.

Cleanup terminates the conversation and its sandbox, deletes the agent and
environment, then deletes the receiver run and verifies 404. The
`mcp-receiver.json` manifest preserves intent before receiver creation. Use the
ordinary cleanup command with the original target configuration after an
interruption; it also reads this manifest and cleans the receiver. Receiver
cleanup is attempted even if a Fountain resource remains, revoking access to
the controlled tools.

The workflow accepts `profile: mcp` for manual public or rollout checks. Store
`FOUNTAIN_MCP_ADMIN_KEY` in the selected protected GitHub environment. MCP is not
part of scheduled canaries. A local receiver or SDK diagnostic does not count
as a deployed Fountain runtime/provider verdict.

## Webhook delivery and retry

The independent `webhooks` profile covers the outbound-delivery half of #1616.
It provisions a run-owned conversation without a prompt, registers an endpoint
through `POST /api/webhooks`, then terminates the conversation. This produces
the documented `conversation.terminate.done` event with zero inference turns.
The signing secret is accepted only from the endpoint's creation response and
is checked for disclosure in subsequent public responses before redaction.

The controlled receiver verifies the HMAC over the timestamp and exact raw
body bytes, with a five-minute replay window. It also verifies the event
headers, attempt counter and metadata-only payload. It returns one 503 for the
first valid event and 200 for later valid deliveries. The suite requires an
automatic later attempt; it never invokes the test-send or redeliver APIs.
Each receiver receipt must match a public delivery record, and the payload
must match the conversation event's ID, timestamp, stage, state and duration.
Conversation status remains advisory, as the
[webhook contract](../docs/reference/webhooks.md#the-payload) specifies.

Delivery is at least once and unordered. Multiple successful deliveries,
repeated attempts and out-of-order public rows are retained for analysis.
They do not fail merely because there are more than two records. The profile
observes for a configured window after successful retry, then reports that
window and all observed delivery IDs. This does not assert that duplicates
can never arrive later. The receiver response precedes Fountain's delivery
record write; the suite waits for these two evidence sources to agree.

Run `deployed/receivers/webhooks.mjs` from the suite checkout on one controlled
HTTPS origin. Route the origin to one process and disable request/header
logging. Set `FOUNTAIN_WEBHOOK_ADMIN_KEY` to at least 32 random characters.
Provide `TLS_CERT_FILE` and `TLS_KEY_FILE`, or explicitly set
`RECEIVER_TLS_AT_INGRESS=true` behind HTTPS ingress. The default port is 8080.
The origin must resolve publicly and be reachable from Fountain's outbound
workers and from the suite. Fountain's SSRF protections remain in force.

The receiver keeps signing secrets in memory to verify HMACs. It never returns
or logs them. Runs expire after 15 minutes; capacity is 32 runs, 64 deliveries
per run and 16 KiB per request. Invalid signatures and unexpected payload
fields are rejected and recorded as booleans without their raw values. Only
verified metadata payloads and generated receipts appear in observations.
Browser origins are rejected. Deleting the receiver run removes its secret.

Copy `deployed/webhooks.example.json` and set the real origins and dedicated
account credentials. Pin the runtime, model and provider for provisioning.
The second account must be distinct and verified. Exactly zero prompts and
at least four resources must be authorized. A run is bounded to ten minutes;
the default delivery deadline is three minutes and duplicate observation is
30 seconds. The endpoint API, signed dispatch and automatic retry are all
required verdicts. A missing worker queue or disabled dispatch fails the
selected profile.

```bash
node deployed/cli.mjs run \
  --config /tmp/fountain-webhooks.json \
  --out /tmp/fountain-webhooks-001
```

Cleanup first attempts to disable and delete the endpoint, then verifies 404.
A failed disable reply does not prevent deletion. Endpoint cleanup precedes
conversation cleanup so teardown does not queue more outbound events. Lost
creation replies retain the endpoint description and exact target URL for
ownership checks. The receiver has a separate `webhook-receiver.json` intent
manifest. The ordinary cleanup command handles both manifests with the
original target configuration. Cleanup failures remain explicit; expiry of a
receiver run does not prove that a Fountain endpoint was deleted.

The report distinguishes provisioning, registration, conversation-event and
background-delivery failures. A separate cleanup snapshot retains the final
receiver observations and public delivery records when those reads succeed.
The analyzed window and snapshot are labeled separately.

Manual CI selection is `profile: webhooks`, with
`FOUNTAIN_WEBHOOK_ADMIN_KEY` in the selected protected environment. It is not
part of scheduled canaries. The `schedules` profile below selects scheduled execution independently.
`one_off` on the current schedule API selects a fresh conversation per firing,
not a cron that deletes itself after one firing.

## Scheduled execution

The independent `schedules` profile covers the scheduled-execution half of
#1616. It creates a fresh agent and environment, then a disabled schedule
through the public teammate schedule API. The agent does not need an existing
team conversation: `one_off: true` opens a new conversation for its firing.
The current API uses cron; it has no once-only timer field.

The suite chooses one date-specific UTC cron about two to three minutes in
the future. It verifies `next_run_at`, records one prompt authorization in the
cleanup manifest, then enables the schedule. A lost enable reply consumes the
same authorization; the suite never enables it again automatically. It does
not call the schedule's `run` action or submit a conversation prompt.

When the generated conversation appears, the suite disables the schedule
before waiting for the turn. It requires a matching public
`last_conversation_id`, a successful `last_run_at` within the configured window,
and a `next_run_at` advanced beyond this date. The completed turn must contain
the scheduled prompt and a paired tool result with the nonce. The nonce file
must also be readable through the public sandbox file API. Model text alone
cannot satisfy these checks.

The conversation has no environment override. Its sandbox must inherit the
run-owned agent's environment, with an ephemeral mode and no vault. These are
separate public fields and are checked separately. Every generated conversation
is recorded for cleanup, including duplicates detected during a failed run.
The existing ownership-marker rules for ordinary conversation fixtures remain
in force; schedule-created conversations have a separate, parent-checked record.

After completion, the suite observes the disabled schedule and its agent's
conversations for at least 120 seconds, spanning two scheduler minutes. It
requires the same single conversation and completed turn throughout that
window. Results record the window and each observation. This proves the
bounded observation with the schedule disabled; it does not claim unbounded
exactly-once delivery or automatic deletion by Fountain. The date-specific cron
would recur annually if it were left enabled.

Copy `deployed/schedules.example.json`, set the target and dedicated account
credentials, and pin the runtime, model and sandbox provider. The primary
account needs working inference credentials; a runner target needs its runner
online. The second account must be distinct and verified. The profile requires
one authorized prompt, an ephemeral sandbox and a four-resource budget. Its
run deadline is at most fifteen minutes. The default dispatch window is three
minutes after the due time; duplicate observation is two minutes. Cleanup must
have at least thirty seconds and defaults to ninety seconds.

```bash
node deployed/cli.mjs run \
  --config /tmp/fountain-schedules.json \
  --out /tmp/fountain-schedules-001
```

Cleanup disables and deletes the schedule before terminating its generated
conversations. A failed disable reply does not prevent deletion. It discovers
conversations through the run-owned agent, checks their identity and sandbox
ownership, terminates them, and verifies their deletion. A short final scan
catches rows inserted by a worker that had already read the schedule. A public
sandbox listing must contain no remaining live sandbox for the agent. An
orphan sandbox or a source that cannot be deleted fails cleanup and retains
the parent fixtures for investigation.

All schedule and generated-conversation identities live in `cleanup.json`.
The ordinary cleanup command can recover them after interruption or a lost
response. It checks the same target, owner, parent markers and schedule marker
before taking action. It never creates or enables a schedule during cleanup.
Its bounded scan does not assert that it can stop an unreachable server or
recover from a hard-killed client without a later cleanup invocation.

Manual CI selection is `profile: schedules`. It uses the protected target's
existing primary and secondary suite keys and a fifteen-minute run ceiling.
It is separate from `webhooks` and is not part of scheduled canaries. A
missing scheduler or failed background firing fails the selected profile;
local fixture diagnostics do not count as a deployed hosted-runtime verdict.
## Deterministic ACP fixture

The `deterministic` profile runs the pinned `fountain-fixture` runtime in a
real sandbox. Use an isolated test instance by default. An explicitly selected
production target must follow [production recovery controls](recovery-controls.md#production-opt-in)
and restrict the fixture to a dedicated test account. On the server,
set both `DEPLOYED_ACP_FIXTURE_ENABLED=true` and
`DEPLOYED_ACP_FIXTURE_USER_ID` to the dedicated, verified test account's UUID.
The runtime is absent by default. Another account cannot create a fixture
agent or start one, and disabling it prevents launch and rehydration. The
normal account suspension, billing, sandbox placement and quota checks still
apply. Keep the fixture disabled for ordinary production accounts.

The fixture is a fixed Node program bundled in
`apps/fountain/priv/deployed/acp-fixture.mjs`. Provisioning writes its exact
bytes to the sandbox; the suite independently reads those bytes through the
public file API and checks their SHA-256 against its pinned checkout. It uses
Node from the sandbox image or runner's PATH and requires Node 18 or newer.
There is no npm install and no arbitrary script URL, command or code supplied
by a tenant. Use the normal real-model profile as separate required evidence.

```json
{
  "base_url": "https://your-test-instance.example",
  "credentials": {
    "primary": "FOUNTAIN_SUITE_KEY",
    "secondary": "FOUNTAIN_SUITE_OTHER_KEY"
  },
  "profiles": ["deterministic"],
  "required_capabilities": {
    "runtimes": ["fountain-fixture"],
    "sandbox_providers": ["runner"]
  },
  "fixture": {
    "sandbox_provider": "runner",
    "provision_ms": 120000,
    "turn_ms": 30000,
    "max_turns": 7
  },
  "limits": {
    "request_ms": 10000,
    "run_ms": 300000,
    "cleanup_ms": 60000,
    "resources": 3
  }
}
```

Run this configuration with the normal `deployed/cli.mjs run` command.
For a runner target, start a real `fountain runner` under the primary test
account, with a separate temporary sandbox root. Its process backend runs
as the runner's user; use a dedicated test machine. Hosted sandbox providers
use the same profile, but require their own provider credentials and validation.
Missing runtime or provider capability fails setup before fixture creation.

Seven sequential prompts check delayed output while a turn is still running,
a real nonce file and follow-up, strict stream/history replay agreement,
permission approval and denial through the public request API, cancellation,
an explicit ACP error, and a successful resume after that error. The permission
checks reject an unknown option and a second tenant's answer. File reads prove
that denied or cancelled work did not write an artifact. Session identity and
the fixture's persisted turn/write counts prove that the final follow-up used
the existing session and wrote the original artifact only once. Each phase
checks its terminal turn and rejects any extra or dangling active turn.
Cleanup terminates the sandbox and removes all three run-owned resources.

`fixture` in the report records process version, source digest, scenario,
permission outcome and session evidence. `prompt_attempts` counts all seven
submissions; `inference_attempts` is zero. The cleanup manifest retains its
legacy `inference_attempts` field as the durable **prompt** reservation counter.
Do not treat fixture success as evidence of model quality, provider inference
credentials, built-in CLI/adapter installation, model selection in those CLIs,
MCP configuration, system prompts or skill consumption. Fixture agents reject
personas, tenant skills and MCP settings instead of silently ignoring them.
The fixture has only one model, `fixture/deterministic-v1`.

This is the narrow host seam for #1611 and gate 1 of #1007. Runtime dispatch
continues to delegate the four built-ins to `Managoat.Runtimes`; the fixture
has a separate name, fixed command, account admission rule and one-turn sandbox
capacity. There is no tenant runtime CRUD, general harness registry, custom
bootstrap or permission claim for arbitrary code. Those remain #1007 work.
The deterministic profile runs separately from real-model canaries and is not
an option in the production CI workflow.

The explicit [staging recovery profile](recovery-controls.md) uses the deterministic
fixture to verify accepted turns, replay and persistent-home artifacts across
rollout and runner reconnection. It includes interrupted-run restoration and a
bounded runner connection relay. A local rollout continuity failure remains under
investigation; #1617 has no passing deployed verdict yet.
