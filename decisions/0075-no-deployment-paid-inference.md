---
type: ADR
title: "No deployment-paid inference"
description: "Managoat holds no inference credential: a conversation runs on its user's ChatGPT subscription or own credential, else nothing."
tags: [inference, codex, security, api]
status: stable
adr: "0075"
adr_status: "Accepted"
date: 2026-10-15
---

# 0075 — No deployment-paid inference

**Status:** Accepted — 2026-10-15. Decided by the maintainer as part of the
cleanup that takes Managoat back to a self-hosted conversational API to a
computer for one operator and his own apps. Built.

Amends [0008](0008-byo-inference-credentials.md) (its 2026-09-02 amendment
no longer holds), [0038](0038-onboarding-first-reply.md) decision 3,
[0053](0053-inference-credential-sets.md) and
[0070](0070-one-chatgpt-subscription-per-user.md). Each has a dated addendum
pointing here.

## Context

Managoat had two ways to pay for a tenant's inference out of the
deployment's pocket:

- **Platform API keys** ([0038](0038-onboarding-first-reply.md) decision 3,
  #1388). `PLATFORM_ANTHROPIC_API_KEY`, `PLATFORM_OPENAI_API_KEY`,
  `PLATFORM_GEMINI_API_KEY`, or a key set at `/admin/inference` and stored
  under the master key. A tenant with no credential of their own for the
  model's provider ran on one. They existed so a stranger could reach a first
  reply on a hosted service, metered against prepaid credits.
- **The deployment's ChatGPT subscription**
  ([0070](0070-one-chatgpt-subscription-per-user.md)). A row of
  `chatgpt_subscriptions` with no user, linked by an admin at
  `/admin/inference`, that every account without its own subscription or
  OpenAI key ran codex on.

Both were built for the hosted service. That service is gone (2026-10-12):
there are no credits, no metering and no strangers. What was left was
machinery whose only remaining job was to let accounts spend the operator's
money without a bound: a `platform` scope in every source, an `origin` field
in the API, a deployment-wide advisory lock that every resolution took
shared, a second encryption path under the master key, an admin page, a
boot-time warning, two audit event families and a keepalive arm. On the
maintainer's own deployment the last turn on a platform credential ran on
2026-09-30.

Each user's own credentials stay: the inference credential record (Claude
OAuth token and API keys), environment and vault variables that name one,
and each user's own ChatGPT subscription (0070).

## Decision

1. **Managoat holds no inference credential of its own.** Removed:
   `Fountain.PlatformInference` and its key schema, `/admin/inference` and
   its tab, the `PLATFORM_*_API_KEY` configuration, the boot-time
   unused-key warning, `Crypto.encrypt_platform/1` and `decrypt_platform/1`,
   the deployment arm of `Fountain.ChatGPT` (owner `:platform`, its admin
   card and its `admin.platform_chatgpt.*` events), the
   `admin.platform_inference_key.*` events, and the deployment-wide
   `inference:platform` advisory lock. `Fountain.ChatGPT` is keyed by user id
   alone. A release that still finds a `PLATFORM_*_API_KEY` variable set
   warns at boot that it is no longer read.

2. **The resolution order.** For a codex run on an `openai/` model on a
   brokered deployment, the user's own ChatGPT subscription; then, for every
   run, the user's own credential for the model's provider (the record's,
   an environment's or a vault's, by the existing selection). Otherwise the
   source is `missing`, as on a deployment that never set a platform key: the
   conversation provisions and the runtime has no credential to call the
   model with. Provider-less models resolve `none`, as before.

3. **The `platform` scope is gone.** `InferenceCredentials.Source` has no
   `:platform` scope, no `platform?/1` and no `origin/1`. A stored source of
   scope `"platform"` loads with no scope. Every stored map still carries
   `"origin"`, and `dump/1` writes `"own"`, because a stored source is
   compared whole with a fresh dump and dropping the key would refuse every
   conversation admitted before.

4. **The API.** A turn's `inference` object loses `origin`, and its `scope`
   enum loses `platform`. A turn that ran on a deployment credential reports
   `inference: null`. This was a breaking change to the generated SDK types,
   released in SDK 10.0.0 (#2730).

5. **Conversations bound to a deployment credential are refused, not
   moved.** Binding is the rule of [0053](0053-inference-credential-sets.md):
   a conversation keeps the source it was admitted on, and a source that no
   longer resolves is `409 inference_source_changed` at the next turn or
   wake. A stored `platform` source can never equal a fresh resolution, so
   such a conversation is refused at its next prompt, and the user starts a
   new one on their own credential. It is not rebound silently: its sandbox
   was prepared for the deployment's credential, and moving it would be the
   silent switch 0053 forbids. On the maintainer's deployment on 2026-10-15
   that was three idle conversations (two on the Anthropic key, one on a
   ChatGPT grant of the retired 0047 design that was already refused).

6. **The turn-start inference stamp stops.** `TurnMachine.with_inference/2`
   wrote `"inference"` (and `"model"` on a platform turn) into a turn's
   `usage` so a platform turn that died could still be seen and billed.
   Nothing prices a turn now, so nothing writes it. The read side stays:
   rows already stamped render `usage: null` until a figure lands, and a
   figure merges over a stamp.

7. **Data.** `platform_inference_keys` is dropped, the deployment's
   `chatgpt_subscriptions` row (the one with no user) is deleted,
   `user_id` is not null, the partial unique index on the null owner is
   gone, and the inference source trigger has no branch for the dropped
   table. The migration shipped a release after the code stopped reading
   both, so a replica of the previous release never read a dropped table
   during a rollout.

## Consequences

- An account with no credential for its agent's provider has nothing to
  run on. The starter agent ([0038](0038-onboarding-first-reply.md)
  decision 4) is planted as before, and its prompt and description now say
  it runs on the account's own credential.
- **Unbuilt: a clear refusal at admission.** A conversation that resolves
  `missing` still provisions, and the failure is the runtime's own
  authentication error inside the turn. Refusing it at
  `POST /api/conversations` with a named error before a sandbox is reserved
  is the better behaviour, but launching with no credential is what most
  of the suite does today (42 cases in the conversation and controller
  suites alone), so it is left for its own change.
  `InferenceCredentials.missing_for_model/2` answers which credential a
  model needs; the console agent form that called it was removed
  ([0076](0076-console-without-configuration-pages.md)), and nothing calls
  it now.
- An operator who set a `PLATFORM_*_API_KEY` sees a boot warning and should
  unset it. A key stored at `/admin/inference` was deleted with its table.
- One encryption path and one advisory-lock key fewer. Account deletion
  takes only the user's own source lock.
- 0008's original position holds again: the deployment pays for no
  inference, and its rejected alternative ("a fallback platform key, tenants
  override") is rejected again.

## Alternatives considered

- **Keep the keys as an operator opt-in.** That is what they were after the
  hosted service ended. With one operator who is also the only account
  holder, a fallback key is the operator's own key under another name,
  reached through a second code path; putting it in the operator's own
  credential record does the same with no special case.
- **Rebind conversations on a platform source to the user's own credential
  at their next turn.** It keeps three idle conversations alive at the cost
  of a migration path through the binding that 0053 exists to forbid. A new
  conversation is cheap.
- **Keep `origin` in the API, always `own`.** A field with one value tells
  a client nothing and keeps the removed concept in the contract.

## History

- 2026-10-15 — Decided and built: deployment credentials, the `platform` scope and `origin` removed (#2728); SDK 10.0.0 (#2730); tables dropped a release later (#2729).
- 2026-10-17 — The agent form that asked for a missing credential is gone (ADR 0076); `missing_for_model/2` has no caller.
