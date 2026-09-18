# Recover after the suite runner disappears

Use a separate trusted machine or process. This procedure does not need the
original GitHub Actions runner, a staging deployment, or a restart of serving
pods. It uses public APIs with the dedicated suite account's full-scope key.
Never use an ordinary customer account for a recovery exercise.

Stop the original job and its retries before cleanup. Establish the exact
instance origin, verified account ID, suite revision/profile, and **suite run
UUID**. The suite UUID is not the GitHub Actions numeric run ID; matrix cells
each have their own UUID. Obtain it from a surviving report/log or corroborate
exact resource markers against the operator's launch record, account, time
window and suite revision. A `suite-` prefix, an arbitrary UUID found on an
account, or a time window alone does not authorize deletion.

## When evidence survives

Copy the results directory, including `cleanup.json` and receiver/control
sidecars, to the recovery machine. Reconstruct the non-secret target JSON from
the approved environment configuration. Verify its `base_url` and credential
role match the manifest's `base_url` and `owner_id`; authenticate with
`GET /api/auth/me` before proceeding. Export the dedicated credentials named
in the target file using your normal credential store. Do not put key values
in evidence, command arguments or Git.

```bash
node deployed/cleanup-replay.mjs --config /tmp/fountain-target.json \
  --results /tmp/copied-results --out /tmp/recovery-pass-1
node deployed/cleanup-replay.mjs --config /tmp/fountain-target.json \
  --results /tmp/copied-results --out /tmp/recovery-pass-2
```

Use fresh output directories. Retain the updated source manifests: replay
updates them as each resource is cleaned. Inspect `replay.json`, each
`result.json`, remaining resources and failures. An empty result directory
is **not** a cleanup verdict; do not use CI's `--allow-empty` for this procedure.
The second pass should report no remaining fixtures and tolerate resources
already removed. An interrupted or failed pass stays failed even if a later
pass succeeds.

## When neither a usable manifest nor an artifact survives

The bounded reconstruction tool supports ordinary `basic`, `execution`,
`streaming` and `deterministic` fixtures: environments, vaults, agents,
suite-created API keys, and conversations with recorded suite parents.
It supports ephemeral and persistent modes. It does not run inference.

The operator must reconstruct **every submitted create intent**, including
one whose response was lost. Compare the exact suite revision's profile code
with surviving launch/request logs and the last known execution point.
`Fixtures.create` assigns `suite-<run-UUID>-<kind>-<zero-based creation index>`
before sending a POST. A combined basic/execution run continues the same
index; do not assume conversation index 2 for every profile combination.
The operator notes below are evidence references for review, not claims the
tool can independently prove.

Read-only discovery produces a candidate, never an executable cleanup plan:

```bash
node deployed/recover-fixtures.mjs inventory \
  --base-url https://fountain.example.com \
  --owner-id 11111111-1111-4111-8111-111111111111 \
  --run-id 22222222-2222-4222-8222-222222222222 \
  --out /tmp/recovery-inventory
```

The tool uses `FOUNTAIN_SUITE_KEY`, or that exact origin's
`fountain-deployed-suite` macOS keychain entry. It emits only resource
identities and parent/sandbox relationships, not API response bodies or
credentials. It refuses account mismatch and redirects.

Review `/tmp/recovery-inventory/evidence.json` and fill:

- `profiles`: the original run's supported profiles.
- `ownership_evidence`: how the exact run UUID, target and account were
  corroborated, including the suite revision and launch/log reference.
- `writers_stopped`: evidence that the original process and retries cannot
  submit new work. Killing a client does not cancel a request on the server.
- `intent_inventory`: how all submitted creates were accounted for. Add
  exact missing names from request logs or the profile's known execution
  point even when no resource is currently visible. Omit `id` when unknown;
  never invent one or copy it from an unrelated resource.
- `queue_account_settlement_evidence`: required for every reconstruction and
  replay, including inventories containing only sources. Record authoritative
  account-wide launch records or deployment-operator findings that establish
  no accepted queue work remains unsettled and account for every resulting
  resource. This must cover work on **all agents in the dedicated account**,
  including per-launch environment/vault overrides and parent conversations.
  Stop every source of new account submissions, including other clients and
  scheduled producers, before establishing settlement; keep them stopped
  through cleanup. Do not infer this evidence from the selected suite profile.
  `GET /api/sandbox-queue` lists only waiting requests; claimed/`starting` work
  is omitted. A known request's detail endpoint can establish its status, but
  neither list nor detail exposes its launch attributes. An empty list, a
  different agent ID or a dead runner cannot prove settlement or independence.
  Unknown request IDs or outcomes require operator escalation. Recovery refuses
  **any waiting request**, even with this note; settle it outside recovery and
  review the evidence again before retrying. The tool never cancels that work.

Earlier `queue_settlement_evidence` notes covered only recovered agents and
are no longer accepted. Reassess the whole account and supply the new
`queue_account_settlement_evidence` field in reviewed reconstruction evidence
or the existing manifest's `recovery` object. Renaming an old note without
the broader investigation does not establish the required evidence.

If the Buzz inventory is unavailable, also review:

- `buzz_absence_evidence`: leave empty when `GET /api/buzz/agents` returns
  its identity inventory. If the extension route returns the host's 404,
  record the deployment operator's evidence that no stored Buzz identities
  reference the recovery fixtures. A fresh core-only database that never had
  Buzz storage is one such case. The same 404 also covers a disabled extension;
  disabling or removing its code does not remove stored foreign-key references.
  Deployment/database history or a scoped operator inspection must establish
  absence; the HTTP response alone cannot. Without that evidence, escalate.
  The note cannot bypass an available inventory, authentication failures,
  malformed replies, or server errors.

For each conversation, retain explicit `agent_id`, `environment_id`,
`vault_id` (UUID or `null`), `sandbox_id` (UUID or `null`), and `sandbox_mode`.
Read `GET /api/conversations/:id` and `GET /api/sandboxes/:id` to corroborate
these. Every non-null parent must be represented by its own exact run-owned
fixture. If an unprovisioned conversation has no embedded mode, establish
the requested mode from its launch configuration. Never infer persistent
mode merely to make a reset pass.

If the last submitted request or complete intent inventory cannot be
established, **stop and escalate**. Two empty listings, a quiet interval,
or the runner being dead cannot prove an unknown request will never commit.
Do not remove a missing intent to obtain a green result. A known submitted
create with no ID and no visible exact match remains pending on every cleanup
attempt; retry after server settlement. If it never committed, an operator
must investigate the request outcome rather than marking it cleaned from
absence alone.

A pending agent that later appears with its exact recorded name and source
references is reconciled before the dependency check. While an agent create
remains invisible, its unresolved intent stays failed and replay retains every
recorded environment and vault. Reconstruction cannot establish the complete
source relationships of a missing agent, so these possible parents remain
until **all recorded agents are cleaned**. Failed agent deletions and lost
delete replies retain sources too; replay must reconcile the agent first.
Account-wide sandbox queue settlement does not establish the outcome of an
ordinary `POST /api/agents` request.

Once the exact agent appears, replay deletes it before releasing sources.
Combined profiles reconcile all agents before any environment or vault,
regardless of their original creation order. Changed IDs/names, duplicate
matches and a reappearing cleaned fixture still refuse the pass.

Reconstruct only after that review:

```bash
node deployed/recover-fixtures.mjs reconstruct \
  --base-url https://fountain.example.com \
  --evidence /tmp/recovery-inventory/evidence.json \
  --out /tmp/recovery-reconstructed
```

This makes only GET requests, checks exact names and IDs, discovers lost
create responses, and writes `cleanup.json`, the reviewed `evidence.json`
and `cleanup-target.json`. Ambiguous names, different owners/modes, missing
parents, unrecorded dependents or an attached schedule refuse reconstruction.
Review those files, export `FOUNTAIN_SUITE_KEY` on the recovery machine, then
use the ordinary cleanup command:

```bash
node deployed/cli.mjs cleanup \
  --config /tmp/recovery-reconstructed/cleanup-target.json \
  --manifest /tmp/recovery-reconstructed/cleanup.json \
  --out /tmp/recovery-cleanup-1
node deployed/cli.mjs cleanup \
  --config /tmp/recovery-reconstructed/cleanup-target.json \
  --manifest /tmp/recovery-reconstructed/cleanup.json \
  --out /tmp/recovery-cleanup-2
```

Every replay of a reconstructed manifest rechecks ownership and dependent
inventory before mutation. Unrecorded agents referencing a fixture through
their environment/vault allowlists, and child conversations linked through
`parent_conversation_id` even when using different resources, block the whole
pass. So do other foreign conversations, sandbox co-tenants, unrecorded
sandboxes, changed parent names and agent schedules. The public Buzz identity
inventory is also checked on reconstruction and every replay: any identity
referencing a recovered agent, environment or vault refuses cleanup, even with
no conversation or sandbox. Buzz identities are not adopted or deleted by
this tool. The public waiting queue is checked on every reconstruction and
replay, including source-only inventories. Any waiting request blocks the
pass: its hidden launch attributes may reference a recovered environment,
vault or parent conversation even when its agent differs. Queue requests are
separate ownership evidence and are neither adopted nor cancelled. An empty
waiting list supplements the operator's account-wide settlement evidence;
it cannot replace it. Refusal retains fixtures as evidence.
Cleanup then terminates recorded
conversations, verifies their sandbox is terminal (and resets only an exactly
owned persistent home), deletes conversations, cleans all recorded agents,
and finally deletes environments and vaults once their agent guard is clear.
A new sandbox discovered after reconstruction can require a fresh inventory
and reviewed reconstruction; refusal does not mean it was cleaned.

If a pass deletes some parents and then fails, their database references on
terminal sandbox history become `null`. Replay accepts that transition only
for the exact recorded sandbox and after a fresh parent-by-ID lookup confirms
its absence. Sandbox mode and co-tenant checks still apply. Live sandboxes,
non-null foreign references and cleared references to parents that still
exist refuse the pass. Recorded sandboxes remain checked even after every
parent reference has been cleared, so a revived sandbox cannot pass unnoticed.

Recovery is bounded to 100 intents, 1,000 rows per public collection, a
2 MiB response, and two minutes for reconstruction. Oversized or paginated
inventories fail. Cleanup retains the ordinary separate 90-second deadline.
A timeout, provider refusal or live sandbox remains a visible failure with
its parents retained; keep evidence and retry after resolving the cause.

## Other profiles and escalation

Surviving manifests retain their existing profile coverage. Schedules must be
disabled/deleted before generated conversations and parent fixtures; webhooks
must be disabled/deleted before conversation teardown can queue more events.
The existing cleanup path does this and retries receiver cleanup from its
sidecar. Keep receiver admin configuration and sidecars with the manifest.

Missing-journal reconstruction intentionally refuses `schedules`, `webhooks`,
`secrets`, `mcp`, `browser` and rollout `recovery` profiles. Their journals
carry evidence not recoverable from ordinary fixture names alone: generated
conversations, receiver sessions/nonces, credential IDs, or disrupted
infrastructure controls. A receiver's expiration bounds its lifetime but is
not proof that Fountain's outbound sources stopped. Do not relabel one of
these profiles as `execution` or drop sidecars to get a passing verdict.

For an unsupported profile, unknown ownership, unknown submitted intents,
unrecorded child/co-tenant, or persistent provider failure, retain the exact
IDs and a read-only snapshot and involve the deployment operator. First
identify and stop each proven run-owned schedule/webhook and active execution
through its public API; revoke or confirm expiration of its exact receiver
session through that receiver's admin API. Reconstruct relationships before
removing any parent. Do not reset an arbitrary sandbox, sweep by prefix,
delete the suite account, or edit server rows. Restore rollout controls using
[the existing recovery guide](recovery-controls.md) if applicable. Record
anything still unresolved and split a demonstrated coverage gap before
expanding this tooling into an automatic sweeper.

## Exercised evidence

See [the September 17 exercise](evidence/1697-runner-loss-2026-09-17.md) for the
selected deployed target, interruption point, deliberately lost evidence,
resources recovered, repeat-pass verdict and inference spending. The live
result establishes only the exercised fixture shapes; the additional refusal
and persistent-home cases have focused harness coverage.
