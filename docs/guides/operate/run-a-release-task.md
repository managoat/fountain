# Run a release task

This guide shows you how to run an operator action that touches data. Each one
of them uses the same pattern.

## The pattern

Compose:

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("you@example.com")'
```

Kubernetes:

```bash
kubectl exec -n fountain deploy/fountain -- \
  sh -c "PHX_SERVER=false bin/fountain_server eval 'Fountain.Release.verify_email(\"you@example.com\")'"
```

`eval` starts the database connection and nothing else. It never starts the
app. So a task cannot compete with the live server for ports, for background
jobs, or for conversation processes.

`PHX_SERVER=false` says that out loud in a container that sets it `true`.
Include it, and the pattern is always safe to paste.

## The tasks

| Task | What it does |
|---|---|
| `Fountain.Release.verify_email("a@b.c")` | Marks an account's email verified, and sends nothing. It is the escape hatch for a mail provider that broke. Since ADR 0011, `EMAIL_DELIVERY=none` self-verifies at registration. |
| `Fountain.Release.promote_admin("a@b.c")` | Grants the admin role. The admin audit trail records it under a system actor. It is the manual alternative to `FIRST_USER_ADMIN=true` (ADR 0011). |
| `Fountain.Release.rebuild_credit_lots()` | Replays every credit ledger and rewrites the lots. Safe to rerun. |
| `Fountain.Release.inventory_sandbox_metadata()` | Prints retained sandbox IDs and counts of absent build and skill metadata. Read-only. Disk manifests remain unverified. |
| `Fountain.Release.backfill_turn_replies()` | Fills the reply column on each turn that closed before the column existed. Safe to rerun. |
| `Fountain.Release.migrate()` | Runs the migrations that are due, by hand. It is what `bin/migrate` runs. They already run at each boot, unless `MIGRATE_ON_BOOT=false`. In that case this, in a Job before the rollout, is how they run at all. That switch never skips it. |
| `Fountain.Release.rollback(Fountain.Repo, version)` | Rolls migrations back to a version. It is a last resort. Read [Upgrade an instance](upgrade.md) first. |

## Inventory older sandbox metadata

Run this read-only task before a rollout that changes old sandbox metadata.

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.inventory_sandbox_metadata()'
```

The JSON report includes every sandbox row whose status is not `terminated`.
It lists sandbox and owner IDs, status, provider, mode and metadata presence.
Counts include active, suspended, failed and unfinished builds. A `pending` or
`starting` build can lack metadata because provision has not finished.

`build_fingerprint_recorded` and `applied_skills_recorded` report database
presence only. The task reads no skill content or provider metadata. It makes
no provider request, wakes no sandbox and changes no row. Repeated calls
return the same report while the database remains unchanged.

`disk_skill_manifests` is always `unverified`. `applied_skills_recorded` is
true when a skills record exists for at least one runtime on the sandbox. A
recorded selection does not prove that a manifest still exists on disk. This
report cannot certify that all live or dormant disks have completed a
migration.

A sandbox with no recorded build fingerprint refuses a configuration reapply
with `409 rebuild_required` and `field: "environment"`. The message explains
that the original build inputs are unknown. The current Environment may have
changed since provision, so do not populate a fingerprint from that row.
Retries leave the selection, configuration revision and disk unchanged.

Ordinary wake first upgrades an absent skill manifest, then reconciles skills.
The upgrade records ownership before any skill is installed or removed. It
uses the recorded applied selection or historical Agent version, plus matching
GitHub source-lock entries for unnamed skills. Once a manifest exists, it is
authoritative: retries do not merge old names back into it. This protects a
personal file placed under a name that Fountain previously removed.

Wake records the applied selection only after reconciliation succeeds. Fresh
provision can record that selection after a best-effort mount, so the database
field alone does not prove that installation completed. Unknown historical ownership
returns `legacy_skill_ownership_unknown` and leaves the manifest absent. This
includes unnamed legacy GitHub skills without source-lock evidence, and disks
with neither an applied selection nor a historical Agent version. Restore the original source lock from a
backup or choose the explicit rebuild path below; do not guess directory
ownership. An invalid manifest returns `invalid_skill_manifest` without skill
writes or deletion. Preserve it for investigation and restore a known valid
backup or rebuild. Removing it would cause legacy recovery to run again.
Reconciliation never supplies an absent build fingerprint.

Reconciliation and manifest upgrades lock the sandbox across connected application
nodes. Concurrent calls return `skill_reconciliation_busy` without changing files.

Before each GitHub install, the manifest records the source and the names
already on disk and in its source lock. Each install commits its discovered names before the next
install starts. An interrupted install leaves a `pending` manifest. Automatic
retries refuse this state with `skill_installation_incomplete` and preserve it.
Remote installation can continue after its application caller dies. Before an
explicit upgrade, quiesce the sandbox and stop all surviving remote installers.
Operator recovery uses only new source-lock names for newly created directories. Stale lock
entries cannot establish ownership of personal replacements. Inline destinations
are recorded before their files are written. Completed manifests still use
the existing ownership map and never merge historical names back into it.

If new files lack new source-lock evidence, the explicit upgrade returns
`skill_installation_incomplete`. Preserve the pending manifest and files.
Restore trustworthy install evidence or use the explicit rebuild path below.
Do not replace the pending manifest with an empty map.
Failed ownership commits retain their evidence for operator recovery, even if
the next selection removes the interrupted skill. A malformed or partial manifest fails closed
with `invalid_skill_manifest` and needs a known valid backup or rebuild.

Older releases do not understand the pending format. Stop old processes that
can reconcile a disk before that disk resumes skill changes on the new release.
For shared sandboxes, include every conversation owner in that check.

To apply a different configuration, start a new conversation on a fresh
sandbox, without an explicit old `sandbox_id`. A persistent agent home can
reuse its old disk; choose a new agent or explicitly rebuild that home.

Only eligible persistent homes support an in-place rebuild. The home must be
`ready` or `suspended`, with no turn in progress or unresolved remote execution.
First copy any work you need from its disk. Then request
`DELETE /api/sandboxes/:id`. That action destroys the old disk; the next prompt
provisions a fresh one and records its build inputs. The conversation and
transcript survive.

An ephemeral sandbox cannot use this reset endpoint: it returns
`422 sandbox_not_resettable`. For an ephemeral sandbox with no recorded build
evidence, use the fresh-conversation path above.

These rules apply to hosted and self-hosted instances. They also apply to
disks that remain dormant through an upgrade. Issue #2102 stays open for disk inventory
and migration evidence before removal of the legacy skill-manifest recovery.

### Inspect or upgrade a retained disk

The database inventory above deliberately does not contact providers. To inspect
one retained disk, use the running release's operator console:

```bash
docker compose exec app bin/fountain_server remote
```

Select a conversation and its owner from the inventory and the admin view.
Use the conversation's recorded runtime, which identifies its skills root.
If it is absent, establish the original runtime before inspecting the disk:

```elixir
alias Fountain.Conversations
alias Fountain.Conversations.{Reapply, Sandbox}
alias Fountain.SandboxSkills
conv = Conversations.get_conversation!("CONVERSATION_UUID", "OWNER_UUID")
sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
handle = Managoat.Sandbox.build_handle(
  Conversations.sandbox_provider_atom(sandbox), sandbox.machine_name
)
SandboxSkills.manifest_status(handle, conv.runtime)
```

The result is `{:ok, :present}`, `{:ok, :missing}`, `{:ok, :pending}`,
`{:ok, :invalid}`, or a provider error. It contains no skill contents. The command reads the actual
provider disk and can wake a suspended machine; it does not write files or
change database status. A sleeping or offline disk that has not been inspected
remains unverified. Record the sandbox ID, runtime, observation time and result
in the rollout inventory. A valid manifest proves its current format and safe
child names, not that its contents have never been edited.

Normal wake performs the upgrade automatically. For an operator-controlled
upgrade without installing or removing skills, first quiesce every conversation
that shares the sandbox and prevent new prompts, reapply and reset operations.
Then use the same console and handle:

```elixir
previous =
  Sandbox.applied_skills(sandbox, conv.runtime) || Reapply.previous_skills(conv)
SandboxSkills.upgrade_manifest(handle, conv.runtime, previous)
SandboxSkills.manifest_status(handle, conv.runtime)
```

For an absent manifest, confirm that either the applied selection or the
historical Agent version exists. With neither, ownership is unknown; restore
that evidence or rebuild. Do not substitute the current Agent's skills.
`upgrade_manifest/3` leaves a completed valid manifest unchanged. It can also
recover ownership for a pending install after all remote installers stop. It
does not install or delete skills. That pending record carries its own provenance and needs no historical Agent
version. Both operations are safe to retry while the disk remains quiesced.
They change no build fingerprint or applied-skills database record.
Resume through normal wake to reconcile the
selected skills and record them after success.

Keep separate evidence for absent build fingerprints, applied selections and
disk manifests, including suspended disks. The legacy recovery path remains
supported until those disks meet the invariant or are explicitly retired.
These commands do not certify fleet-wide completion of #2102.

## Warnings

Use `rollback/2` to reverse one migration that you understand. Do not attempt
to reverse a whole release's migrations on production data.


## Related

- [Upgrade an instance](upgrade.md).
- [Start billing](billing.md).
- [Nobody can log in](../../troubleshooting/nobody-can-log-in.md), which is
  where `verify_email/1` matters.
