---
type: ADR
title: "Measured environment cache admission"
description: "Decide whether to probe and build an opted-in environment cache from bounded cold and warm provisioning evidence."
tags: [sandbox, environments, performance]
status: stable
adr: "0092"
adr_status: "Accepted"
date: 2026-10-16
---

# 0092 — Measured environment cache admission

**Status:** Accepted. Implements the follow-up in
[#2916](https://github.com/managoat/managoat/issues/2916) to
[0090](0090-portable-environment-layers.md).

## Context

The [production measurements](https://github.com/managoat/managoat/blob/main/contributing/environment-layer-measurements.md)
showed a cheap fixture provisioning in 5.991 seconds cold versus 58.793 seconds
cached. Its 52.385-second filesystem probe dominated a 695-byte artifact.
Managoat itself took 297.798 seconds cold versus 173.268–235.393 seconds cached,
with a 570 MB artifact and a 514-second successful background build. Transfer
and extraction costs varied substantially. These few observations establish the
need for a policy, not universal thresholds or latency percentiles.

Comparing cache hits to misses hides probing overhead because both probe.
Artifact bytes alone cannot predict the benefit. A background build is still
work even when its elapsed time is outside the launch's critical path.

## Decision

Gate cache use before filesystem probing. Explicit environment opt-in and an
operator-configured store remain prerequisites. Disabled, unsupported or
unconfigured launches do not compute an economics cohort or read its evidence.
A failed policy lookup leaves ordinary cold provisioning available.

Keep one bounded evidence row per environment, scoped by its owner. Its
cohort is a tenant-keyed digest of input generation, networking revision,
provider, store identity, server release, boot script, persisted agent
configuration, runtime, and the selected vault's secret revisions. Do not
include per-conversation callback keys, broker vaults or runtime sessions.
Never persist configuration or secret values in the evidence row. Switching
cohorts deliberately discards the previous cohort's samples: alternating agents
or vault configurations can therefore stay cold. This conservative first policy
trades hit rate for a strict storage bound and avoids mixing incomparable work.

1. Collect three successful complete cold provisions with caching bypassed.
   Failed controls remain evidence; six controls without enough successes suspend
   learning. Cache misses and failed restores are never cold controls.
2. Admit at most one exploratory cache launch at a time. Other launches stay
   cold. While a background build is queued/running, launches stay cold without
   probing again. Permit at most six completed cache trials to acquire three
   successful warm observations with known build costs. A lease expires after
   30 minutes and records an interrupted trial; stale completions are fenced.
3. Compare median complete provisioning time, including provider creation and
   owner finalization. A restore followed by a fresh cold fallback is charged its
   original full elapsed time. Failed provisions cannot establish a benefit.
   Add completed relevant builder elapsed costs, including failed sibling builds,
   divided by a **ten-hit planning horizon**. Ten is a policy assumption, not an
   estimate of future use or a CPU/dollar accounting model. Unknown build costs
   cannot establish the required three successful warm observations.
4. Enable normal reuse only when the median estimated saving is at least 20%
   and five seconds. Retain it while saving is at least 10% and five seconds.
   Use up to five recent successful cold controls and five recent cache outcomes;
   a lone transfer stall cannot reverse a median. Established warm reuse is not
   serialized; one in ten launches is a cold control.
5. Keep at most six cold, twelve cache and six miss observations. Separate bounds
   prevent frequent warm launches from evicting all cold controls. Suppressed
   caching stays cold for twenty launch decisions or one day, then learns again.
   All evidence also expires after one day. Input/cohort/release changes reset
   immediately. A newly observed artifact fingerprint resets the epoch and
   fences older concurrent completions. This bounds reevaluation of mutable
   repository refs and platform changes not discoverable before a probe.

The savings margins, sample thresholds, planning horizon and cooldown are
explicit policy choices. They are intentionally not fitted to either measured
fixture and are exposed in decision evidence. They can be revised with more
operational evidence; they are not user-configurable overrides of security checks.

Persist complete launch elapsed time and success/failure, probe, transfer,
combined authentication/extraction, reusable setup, boot, remaining setup,
artifact bytes and known builder elapsed cost. Unreached/unknown phases remain
absent rather than being invented as zero. Remaining setup is wall-clock time
outside the serial measured portions; concurrent adapter work is not added twice.
Builder phase/publication diagnostics remain in their own sanitized audit events.

A `cache_policy` stage with state `done` reports `attempt` or `skipped`, reason,
sample counts and timing evidence. A skip is not a cache failure.
`checkpoint_restore/done` continues to mean only a successfully finalized warm
restore. All actual restore attempts retain authenticated artifacts, exact base
compatibility, fresh identity ordering and the existing one-fresh-machine fallback.

## Consequences

Opting in no longer promises an immediate builder on the first launch. Cheap
workloads pay a bounded learning cost before future probes and builds are
suppressed. Low-frequency environments may never accumulate enough evidence;
this is preferable to claiming a benefit from one sample. Failed launches and
unknown builder costs can leave caching disabled even when a future attempt
might succeed. The policy never cancels an already accepted builder merely
because its current evidence window changes; existing lifecycle cleanup applies.

The first implementation retains only the latest configuration cohort for an
environment, and uses a declared ten-hit amortization horizon. Multiple bounded
cohorts and predictions based on measured reuse frequency remain unbuilt.

## Alternatives considered

- Always attempt an opted-in cache: the cheap fixture demonstrated a large regression.
- Compare hit against miss: both include the expensive probe and bias the comparison.
- Skip small artifacts or short build scripts: size and script text do not establish elapsed cost.
- Automatically restore without inventory: would weaken compatibility and safety.
