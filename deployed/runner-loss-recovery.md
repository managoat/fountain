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
inventory before mutation. New or foreign conversations, sandbox co-tenants,
unrecorded sandboxes, changed parent names and agent schedules block the
whole pass, retaining parents as evidence. Cleanup then terminates recorded
conversations, verifies their sandbox is terminal (and resets only an exactly
owned persistent home), deletes conversations, and finally deletes parents.
A new sandbox discovered after reconstruction can require a fresh inventory
and reviewed reconstruction; refusal does not mean it was cleaned.

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
