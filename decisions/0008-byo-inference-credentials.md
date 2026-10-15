---
type: ADR
title: "BYO inference credentials per tenant"
description: "A user supplies their own inference credentials, encrypted with their key; Managoat holds no inference key of its own."
tags: [secrets, inference, billing]
status: stable
adr: "0008"
adr_status: "Accepted"
date: 2026-05-10
generated: { by: human:jhgaylor, at: 2026-05-10T05:00:20-04:00 }
---

# 0008 — BYO inference credentials per tenant

**Status:** Accepted, 2026-05-10, and built.

## Context

Sandboxed agents need to authenticate to inference providers (Anthropic,
OpenAI, Google). Up through PR #24, the four credentials Managoat knew about
(`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`,
`GEMINI_API_KEY`) were platform-level env vars injected into every tenant's
sandbox by the runtime modules. aod-ex ([0002](0002-aod-ex-as-reference.md))
does the same; it is single-tenant, so one platform key is fine.

For a multi-tenant server this raises three problems that the parallel
decision for Sprites ([0005](0005-platform-shared-sprites-token.md)) does not:

1. **Cost is unpredictable per tenant.** Inference is the dominant cost of an
   agent product. One sandbox is roughly one sandbox, but a turn on Claude Opus
   costs 100 times one on Haiku, and tenants choose their models. Whoever holds
   the key cannot price predictably.
2. **Users want to bring their own Claude subscriptions.**
   `CLAUDE_CODE_OAUTH_TOKEN` exists so users can bill against their own
   Claude.ai subscription instead of metered API. For many it is the only
   economically viable way to run many agent turns.
3. **No isolation argument carries over from Sprites.** There is no isolation
   primitive for inference: one shared key makes every tenant's traffic one
   identity at the provider, which is bad for tenants who want their own usage
   attribution and a legal exposure for the deployment.

## Decision

Managoat holds no inference credential of its own. Each tenant supplies their
own tokens for the providers they use, and the deployment pays for no
inference.

- An `inference_credentials` table, one row per user, with four nullable
  ciphertext columns (`anthropic_api_key_ciphertext`,
  `claude_code_oauth_token_ciphertext`, `openai_api_key_ciphertext`,
  `gemini_api_key_ciphertext`), each encrypted with the user's per-tenant DEK
  (`Fountain.Crypto`).
- `Fountain.InferenceCredentials` handles get, put and decrypt. Plaintext is
  never stored or logged.
- `Fountain.InferenceCredentials.Validator` pings each provider on save (a
  cheap auth-only call), so a typo or revoked key fails at the boundary instead
  of mid-turn.
- `ConversationServer` loads the tenant DEK and decrypts the credentials at
  provision and passes them to the runtime module's `default_env/2`. Plaintext
  lives only in the GenServer's state for the conversation's lifetime.
- The runtime modules (`Managoat.Runtimes.*`, in `apps/fountain/lib/managoat/`)
  read from that map, never from application config.
- The settings page `/account/inference-credentials` and
  `/api/account/inference-credentials` set and clear each credential.
- The platform env vars were removed from the deployment config.

## Consequences

- The deployment pays nothing for inference; tenants pay their providers
  directly, and attribution is per tenant by construction.
- A first conversation needs a credential set first. Validate-on-save and
  accepting any one of four providers keep that cheap.
- Plaintext lives in `ConversationServer` state for the conversation's
  lifetime, the same trust posture as the per-tenant DEK and vault secrets:
  process memory is the boundary. Credentials are dropped on `terminate/2`
  (best-effort in the BEAM; rely on GC).
- `Fountain.Crypto.load_tenant_key/1` is load-bearing for inference: a user
  whose DEK cannot be unwrapped cannot run conversations until it is
  recoverable. The same risk already applies to vault and environment secrets.
- Stored credentials are never echoed back; the page shows "Set" or "Not set".
  A user who loses a key re-pastes it.
- Validation makes a real network call on save (about 200 ms, no quota). If a
  provider is down, the save fails; saving unvalidated would defer the failure
  to the worst moment.

## Alternatives considered

- **Platform-shared credentials, like Sprites (0005).** The implicit model at
  first; rejected for the three problems in Context.
- **Reuse the Vault primitive** (an auto-created "Inference" vault per user).
  Convention-based, a poor fit for a fixed set with provider semantics, and
  leaves the validator no clean home.
- **Fields on `users`.** Couples identity rows with secret blobs; every account
  read would pull ciphertext.
- **A fallback platform key that tenants override.** The cost-attribution
  problem returns for every tenant who does not override. It was built for a
  while (below) and removed for that reason.

## History

- 2026-05-10 — Accepted: per-tenant BYO credentials, no platform inference keys; with a required "connect a provider" onboarding wizard step.
- 2026-09-02 — [0038](0038-onboarding-first-reply.md): the deployment holds platform keys and runs an account without its own credential on them, metered against credits; the tenant's own credential always wins (#1388). The wizard is gone.
- 2026-10-12 — Credits removed with `ee/` (#2609); platform keys are no longer metered.
- 2026-10-14 — Platform keys offered only on a deployment that brokers egress ([0019](0019-egress-credential-brokerage.md)).
- 2026-10-15 — [0075](0075-no-deployment-paid-inference.md) removes the platform keys and the deployment's ChatGPT subscription; the original decision holds again.
