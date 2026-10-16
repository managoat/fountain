---
type: ADR
title: "Fountain runs as one node"
description: "One BEAM, never two at once: Kubernetes deploys with Recreate and the registries and supervisors are local."
tags: [deployment, runtime, conversations, sandbox]
status: stable
adr: "0072"
adr_status: "Accepted"
date: 2026-10-14
---

# 0072 — Fountain runs as one node

**Status:** Accepted, 2026-10-14 (Jake, on the complexity review tracked in
#2676). **Amends:** [0058](0058-the-machine-has-one-owner.md) (stage 6a's
wake marker goes), [0017](0017-suspend-idle-sandboxes.md) (its rolling-deploy
loss window cannot recur). **Supersedes:** the assumption, never written as an
ADR, that Managoat runs as an Erlang cluster of several replicas.

## Context

Horde and libcluster arrived in `e8617b0e`, the 2026-05-10 "phase-3
foundation" commit that scaffolded the server for the multi-tenant hosted
service [0003](0003-direction-option-b-api-ui-onboarding.md) chose. 0003 is
Retired: since 2026-10-12 Managoat is a self-hosted application, and prod runs
one replica.

The cluster support stayed, and it cost more than its two dependencies. Horde's
registry is an asynchronous CRDT, so "no server registered" read on one node
was never proof that none was running on another. Every reader that decided
something durable on a lookup had to carry a second answer for that case:

- the `woken_at` marker (0058 stage 6a), committed under the per-sandbox lock
  before `start_child`, which the reaper's two liveness passes and the park
  honoured for fifteen minutes;
- `Fountain.Drain`, a distribution strategy that kept Horde from placing
  children on a node shutting down;
- the rehydrator's wait for cluster membership and its leader election;
- `PromptDelivery.understands?/1`, an `:erpc` call that asked the receiving
  node whether its release understood the four-element prompt messages;
- `rel/env.sh.eex`, which named Fly nodes after their private IPv6 address,
  and `CLUSTER_DNS_QUERY`'s DNSPoll topology;
- a cluster-wide `:global` lock around skill reconciliation, and
  registry-settle polling after a start.

A rolling deploy also ran two releases against one database at once, which
is what made 0017's loss window and the upgrade guide's cluster floor
necessary.

## Decision

Managoat runs as exactly one node, and two BEAMs never overlap.

1. **Deploys stop the old node before the new one starts.** The Kubernetes
   baseline uses `strategy: Recreate` with one replica, and its
   PodDisruptionBudget is deleted. Fly runs one machine (`fly deploy
   --ha=false`) with the `rolling` strategy, which on one machine stops it
   before starting the new release. A deploy therefore has a gap, about 30 s,
   in which the API answers nothing; the boot sweep (`Rehydrator`) starts a
   server again for every conversation that had one.
2. **The registries and supervisors are local.** `Fountain.ConversationRegistry`
   and `Fountain.MachineRegistry` are Elixir `Registry`s;
   `Fountain.ConversationSupervisor` and `Fountain.MachineSupervisor` are
   `DynamicSupervisor`s with the same restart budgets. libcluster and Horde are removed from the dependencies.
3. **A registration happens under the lock.** `Conversations.register_server/2`
   starts the child inside its per-sandbox advisory-lock transaction.
   Registration is synchronous, so the server is registered before the lock is
   released, and a reader that takes the lock after it finds the server. This
   replaces the `woken_at` marker, whose column is dropped. It puts one rule on
   `ConversationServer.init/1`: it does no database work, because it runs
   inside that transaction.
4. **What existed only for the cluster goes.** `Fountain.Drain`, the
   rehydrator's membership wait and election, `PromptDelivery.understands?/1`,
   `rel/env.sh.eex`, the `CLUSTER_DNS_QUERY` topology and the documentation
   for running several replicas. The skill-reconciliation lock is taken on this
   node only. `Machine.ensure_started/2` no longer polls for a winner that
   registered elsewhere.

What stays, because it is not about the cluster: the per-sandbox advisory
lock, the `FOR UPDATE` row locks, the durable `transition` column and the
epoch compare-and-set of [0058](0058-the-machine-has-one-owner.md). A provision
runs in a `ConversationServer` while a park or a destroy runs in the machine's
owner, and the provider round trip sits between deciding and writing (#2307),
so two processes on one node still need them. The 0058 lease itself is
reduced to a holder of this boot, with a boot sweep, as 0058 records.

An interrupted `resuming` operation keeps its stamp across the boot sweep
(#2560). Sprites' resume only looks up the machine; the resume owner now runs
a no-op exec before finalizing readiness. A failed implicit wake keeps a
`ready` row stamped `resuming`, preserving its lifetime clock while refusing
file reads. Registration and rehydration must not erase that stamp; the next
wake takes over, re-admits and proves exec readiness. A parked row stays
`suspended` on failure. The owner retries transient exec failures within a
60-second budget, with the SDK's synchronous startup potentially overrunning
it. Background wakes wait up to two minutes for the owner so a normal cold
boot does not lose the queued prompt to the former 20-second caller timeout.

One subtlety of the local registry: it drops an exited process's entry a
moment after the exit, so a lookup can briefly return a pid that has gone.
`ConversationServer.whereis/1` reads such a pid as no server; the machine
owner's callers already retry a gone owner once.

## Consequences

- **Every deploy is a short outage.** Batch merges. A request during the gap
  fails to connect; clients retry, and conversations come back through the
  rehydrator. Turns in flight at shutdown are interrupted as before.
- **No horizontal scaling.** More than one replica is unsupported, not merely
  undocumented: two nodes would be two schedulers over the same sandboxes and
  two unconnected registries. Scaling up means a bigger node.
- **Upgrading needs the deployment changed first.** A rolling deploy of this
  release would briefly run two unclustered nodes. The upgrade guide says to
  switch to one replica with Recreate before taking it; the maintainer's prod
  overlay is changed in the home-cloud repository before this ships.
- **Mixed-release messages stop mattering.** A prompt message can change shape
  without asking the receiving node, and 0017's rolling-deploy loss window
  (an old node waking a row whose status it does not know) cannot recur. The
  upgrade guide's cluster-floor notes stay as history.
- `RELEASE_COOKIE`, `CLUSTER_DNS_QUERY` and `FLY_PRIVATE_IP` are no longer
  documented; the release still generates a cookie for `remote` and `rpc`.
- About 1,150 lines of code, tests and documentation are removed, net.

## Alternatives considered

- **Keep the cluster support, run one replica.** That is what prod did; the
  code paid for a topology nobody ran, and every new reader had to reason about
  CRDT lag.
- **Keep Horde with one member.** Same API, but the registry stays asynchronous
  and the reasoning built on that stays with it.
- **Rolling deploys with one replica (`maxSurge: 1`).** Two BEAMs overlap for
  the length of the readiness wait, unclustered once Horde is gone: two
  rehydrators, two reapers, two registries. Recreate's gap is the price of
  never overlapping.

## History

- 2026-10-14 — Decided and built: one replica with `Recreate`, local registries and supervisors, libcluster and Horde removed (#2676).
- 2026-10-14 — `Fountain.RunnerRegistry` removed with the self-hosted runner provider (#2682).
- 2026-10-15 — The `woken_at` column dropped (#2725).
