---
type: ADR
title: "One inference credential record per user, resolved into a durable binding"
description: "Each user has one inference credential record; a conversation resolves its source at launch into a durable binding with a revision, and a key rotated in place keeps the conversation running."
tags: [inference, billing, security, conversations, accounts]
status: stable
adr: "0053"
adr_status: "Accepted"
date: 2026-09-12
generated: { by: claude-fable/5.1, at: 2026-09-14T07:45:43-04:00 }
verified: { by: claude-opus/5.5, at: 2026-10-14T12:00:00-04:00 }
stale_after: 2026-11-13
---

# 0053 — One inference credential record per user, resolved into a durable binding

**Status:** Accepted, 2026-09-14 (#2176 decision 5). Built. The named sets
the title describes were built and then retired on 2026-10-14: an account
holds one credential record. What stands is the resolved source, its
binding to a conversation, and the rules for a tenant secret and a rotated
key.

Extends [0008](0008-byo-inference-credentials.md). Relies on
[0073](0073-one-sandbox-per-conversation.md) (one sandbox per conversation),
[0070](0070-one-chatgpt-subscription-per-user.md) (a user's ChatGPT
subscription) and [0075](0075-no-deployment-paid-inference.md) (no
deployment-paid inference).

## Context

Two tenants asked for several credentials per account: a business serving
end customers, each on their own key, and a user holding several Claude
subscriptions who wanted a second agent on a second one. Building that
exposed three problems that outlived the feature.

A tenant secret already overrode an inference credential, invisibly. A vault
or environment secret named `ANTHROPIC_API_KEY` wins in the sandbox
environment, which is documented behaviour tenants rely on. But the
admission gate and selection read only the credential row, so on a
deployment with platform keys the conversation was selected and billed as
platform inference, and counted against the platform's daily ceiling, while
the tenant's own secret served every turn. This was live on the hosted
deployment from 2026-09-03 until #2023 and #2025 fixed it on 2026-09-13.

Credentials were written to a shared file. `/home/sprite/.env` was written
once per machine, and a sandbox then carried several conversations; a
credential there was a cross-conversation read.

A conversation that resolves its credential again at each turn can silently
move to another key or another payer when configuration changes underneath
it.

## Decision

### 1. One typed credential record per user

`inference_credentials` holds at most one row per user (unique on
`user_id`) with four ciphertext columns under the per-tenant DEK:
Anthropic API key, Claude Code OAuth token, OpenAI API key and Gemini API
key. It is typed, not a vault: `InferenceCredentials.Validator` pings a
provider on save, the console reports which providers are present without
decrypting, and the broker's binding to the provider host attaches.
`/api/account/inference-credentials` manages it.

### 2. Selection returns a source

One runtime-aware resolver (`Fountain.InferenceCredentials.Resolver`) serves
admission, provisioning and usage attribution. It returns an
`InferenceCredentials.Source` with the values, never containing bearer
material: `scope` (`credential` the user's record, `tenant_secret` an
environment or vault secret, `grant` the user's ChatGPT subscription,
`none` a provider that needs no credential, `missing` a provider that needs
one the user lacks), the credential `kind`, an `identity` naming where the
value is read from, a `revision` that moves when the value is replaced,
`set_id` (the record's id), and the model, runtime, environment and vault.

Precedence:

1. For a codex run on an OpenAI model on a brokered deployment, the user's
   ChatGPT subscription, ahead of any API key (0070). Its access token goes
   to the broker as `CODEX_CHATGPT_ACCESS_TOKEN`; conflicting inference
   inputs do not override it.
2. Otherwise the user's own key. Vault wins over environment on the same
   name, and those overrides win over the record for the same credential
   kind. Supported aliases are normalized, conflicting values for aliases of
   one kind within a layer are rejected, and then the runtime's
   credential-kind precedence applies (Claude prefers OAuth).
3. Nothing else. The deployment pays for no inference (0075), so a user with
   neither is `missing`.

A winning environment or vault secret is the source, with scope
`tenant_secret`; it is neither reserved nor rejected. What was wrong with
the override was that it was invisible, not that it existed. Competing
inference auth inputs for the selected runtime and provider are removed
from the launch so a second variable cannot change authentication after
selection; unrelated tool secrets are untouched.

Admission at `start_conversation` resolves with the launch's environment and
vault before anything is provisioned. Admission checks a snapshot, so
provisioning validates the source again before writing auth state or
starting a peer. Resolution and every credential write take the user's
source lock; database locks are released before sandbox or provider I/O.

### 3. A conversation is bound to its source

The conversation persists its resolved source, and each turn snapshots the
one that served it. Wake, resume, turn admission and provisioning validate
that binding rather than resolve the account's current state again:

- **Identity changed: refused** with `inference_source_changed`. Another
  record, environment, vault or secret row, another credential kind, a
  deleted source, a secret deleted and written again, or another model,
  runtime, environment or vault. Everything in the stored source but
  `revision` must equal the fresh one (`Source.rotation?/2`). No
  conversation silently moves to another payer or key.
- **Same identity, new revision: accepted** for scope `credential` or
  `tenant_secret`, on any runtime. A wake or provision stores the fresh
  revision; a running server keeps the one it was bound with, and turn rows
  record that.
- **A subscription** (`grant`) follows 0070: its revision is the linked
  account, a token refresh keeps it, and a different account asks for a
  reconnect.

A stored source is compared whole with a fresh dump, so a stored key cannot
be renamed or dropped without ending every conversation admitted before.
That is why `set_id` keeps its name and every stored source still carries
`"origin" => "own"`. Sources bound under retired designs (a deployment's
`platform` source, a subscription of the 0060 design) equal no fresh dump
and are refused at their next turn rather than moved to the user's own
credential.

A plain `env_vars` variable's revision is its own: an HMAC of its identity
and value under the tenant's DEK, truncated, so it says nothing about the
value and moves only when that variable does. Secret rows keep their own
`inference_revision`. The credential record has one revision across its
four keys; an edit to another key is a rotation of the same identity, so it
is accepted and changes nothing.

### 4. The next turn runs on the rotated value

`Fountain.Conversations.InferenceRotation` applies a rotation before the
next turn. A running turn finishes on the value it started with.

- **Brokered:** the value is in the broker's rules. The refresh before each
  turn (#1736) and the live refresh a secret write sends (#2548) put the new
  value there and keep the session token, so the idle peer keeps running
  and a secret rotated mid-turn reaches that turn. Codex's
  `~/.codex/auth.json` holds the key's placeholder
  (`Fountain.Broker.placeholder/1`), the same for every value, so it is
  left alone.
- **Unbrokered:** the value is in the adapter process's spawn env. The
  server swaps it in and closes the idle peer, and the next turn starts a
  new adapter that resumes the session. For codex, which reads its key from
  `auth.json`, the server first rewrites the file (mode 600, the shape
  provisioning writes); if the write fails the turn fails with
  `{:codex_auth_write, reason}` before it starts, and the next turn tries
  again.

### 5. Inference auth inputs stay off disk

Every supported runtime's inference credential variable and alias is in
`Conversations.Identity.@process_only`, so `disk_env/1` strips it before
`/home/sprite/.env` is written. Each spawn, setup script included, receives
its resolved inputs through `env:`. This prevents stale credentials on disk;
it is not a security boundary between processes that can inspect each
other. Codex's `auth.json` is the exception its runtime requires, written
at provision and on every reattach.

### 6. A business with many customers uses an account per customer

Credentials are not a tenancy mechanism. Per-customer isolation is an
ordinary account per customer, with its own DEK, credential record and
audit trail.

## Consequences

A setup script that re-read `.env` in a later shell to recover a provider
key must take it from its own environment instead.

Rotating a key in place keeps its conversations running; replacing where the
value comes from ends them at their next turn. Nothing tells a conversation
its key was rotated. The decision rests on the behaviour: the frequency of
`inference_source_changed` in Loki was not measured before deciding.

Automatic failover when a subscription is exhausted is not built. It needs
per-runtime quota-error detection, per-credential cooldown state, and a
mid-turn environment rewrite with a session restart.

## Alternatives considered

- **Named credential sets, chosen per agent and per launch.** Built and
  retired (see History). With one operator, only one production account ever
  held more than one set; the rows, agent and launch columns, allowlist and
  API did not earn their keep.
- **A vault per credential.** Works with no code, but vault values are not
  validated, not reported and were invisible to the gate, and a vault naming
  a credential of a different kind puts both `CLAUDE_CODE_OAUTH_TOKEN` and
  `ANTHROPIC_API_KEY` in the environment, which
  `Managoat.Runtimes.Claude.default_env/2` exists to prevent.
- **Reserve the static credential names** so a tenant secret cannot supply
  them. Breaks documented behaviour tenants use, to no benefit.
- **Re-resolve at every turn.** Simple, and lets a conversation silently
  move to another key or payer.
- **Refuse any change of revision.** The original rule. It ended every
  conversation whose key was rotated, though the safety reason (no silent
  move to another payer or key) is about identity, not value.
- **Put the credential in the sandbox identity.** Forked a persistent home
  per credential while sandboxes were shared; moot since one sandbox per
  conversation.

## History

- 2026-09-13 — The #2018 stack (#2019, #2022, #2023, #2025, #2027, #2028,
  #2031, #2034, #2042–#2046) built named sets with a default, agent selection
  and launch allowlists, the source carrier and resolver, durable bindings,
  process-only inputs, an interim Codex machine binding for shared
  `auth.json`, and an owner route for principals' credentials; #2023 and
  #2025 fixed the invisible tenant-secret override.
- 2026-09-14 — Accepted (#2176 decision 5), amending 0052's "no per-agent
  preference".
- 2026-09-20 — [0060](0060-many-user-chatgpt-subscriptions.md) let a set name
  a ChatGPT grant, with a per-grant `CODEX_HOME` outside the machine binding.
- 2026-10-12 — Principals and the owner credential route removed with
  [0044](0044-claimable-principals.md).
- 2026-10-13 — ChatGPT subscriptions of 0047/0052/0060 retired (#2642), and
  rebuilt the same day in smaller form by 0070 (#2644, v0.22.0): a
  subscription is not named by a set and is written to the one shared
  `auth.json`.
- 2026-10-14 — Named sets retired: migration `20261014120000` kept each
  account's default (#2658), and `20261014140000` (#2659) dropped the set and
  agent/launch columns and restored the unique key on `user_id`.
- 2026-10-14 — One sandbox per conversation (0073, #2676) removed the Codex
  machine binding (`codex_inference_conflict`).
- 2026-10-15 — No platform source (0075): resolution ends at `missing`, and
  the `inference:platform` lock is gone.
- 2026-10-15 — A key rotated in place keeps its conversation on every
  runtime, codex included, and plain `env_vars` get per-key revisions
  (#2602).
