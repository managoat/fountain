---
type: ADR
title: "An account holds several inference credential sets"
description: "Proposed, none built: inference_credentials becomes one row per named set, an agent names its default and a launch may override it, selection returns a source identity, and a tenant secret shadowing a static credential resolves that source instead of silently overriding it."
tags: [inference, billing, security, conversations, accounts]
status: draft
adr: "0053"
adr_status: "Proposed"
date: 2026-09-12
generated: { by: human:jhgaylor, at: 2026-09-12T00:00:00-04:00 }
stale_after: 2026-10-12
---

# 0053 — An account holds several inference credential sets

**Status:** Proposed; none of the behavior below is built. Checked against
`main` at `653af872` on 2026-09-12. Tracker #2018.

Extends [0008](0008-byo-inference-credentials.md) (one credential row per
tenant) and [0038](0038-onboarding-first-reply.md) decision 3 (platform keys
and the selection rule). Amends [0052](0052-user-owned-chatgpt-grants.md)
decision 4 on one point, named in decision 3 below. Constrained by
[0023](0023-persistent-agent-sandbox.md) (a sandbox is shared) and
[0044](0044-claimable-principals.md) (a shared service account is not
isolation).

## Context

Two tenants have asked for the same sentence and need different things.

The first runs a business on one account and manages several end customers
through it. Each end customer should run on that customer's inference
credential and never on another's.

The second holds several Claude subscriptions because one project exhausts
the quota of one subscription, and wants a second agent to run on a second
subscription.

`inference_credentials` is one row per user with four nullable ciphertext
columns and a `unique_constraint(:user_id)`. `InferenceCredentials.select/4`
is the whole selection rule and reads that one row. There is no way to say
"this agent, that key".

Three facts make this less obvious than adding a column.

**A tenant secret already overrides an inference credential, and the override
is invisible.** A vault or environment secret named `ANTHROPIC_API_KEY` wins
in the sandbox environment; `Conversations.Egress` says so at the split
(`egress.ex:223-226`) and `docs/concepts/secrets.md` publishes it. But
`PlatformInference.gate/3` and `select/4` both ask
`InferenceCredentials.has_own?/2`, which reads only the credential row. So on
a deployment that holds platform keys the conversation is selected
`:platform`, `TurnMachine.with_inference/2` stamps `"platform"`,
`Workers.CreditPricer` bills the tenant for platform inference, the turn
counts against `PLATFORM_INFERENCE_DAILY_CENTS`, and `check_ceiling/0` can
refuse a later turn — while the tenant's own secret is what actually served
every one of them. This is live on the hosted deployment, which has held
platform keys since 2026-09-03. #1941 corrected an adjacent facet on
2026-09-12 (a platform turn is now stamped when the deployment holds no
platform API key at all); it did not reach this one, because the stamp is
still derived from a selection that cannot see the secret.

**Credentials are written to a shared disk.** `SpriteEnv.build/4` puts the
inference pairs in the list that `Provisioning.write_env_file/2` renders to
`/home/sprite/.env`. A sandbox carries several conversations (ADR 0023) and
that file is written once per machine. It is benign today only because every
conversation on an account shares one credential. `Conversations.Identity`
already holds the mechanism and the reasoning for the alternative: the broker
proxy address is process-only because "on disk it would be a
cross-conversation read of a credential that brokers another tenant's vault".

**ADR 0052 is mid-build on the same ground.** #2010 merged it as Proposed;
#2011-#2015 and #2017 build its decisions 1, 3 and 6 — scoped grant storage,
coordinated refresh, and a reserved managed credential that configuration may
not name. Its decisions **4 (selection) and 5 (sandbox identity) are
unbuilt**, and they are what this ADR needs. Building a second selection
refactor beside that stack would guarantee a collision, so this one is cut in
the shape 0052 decision 4 asks for and the grant work extends it.

## Decision

### 1. A credential set is a row, not a vault

`inference_credentials` becomes one row per **set**: a `name`, an
`is_default` flag, and the same four ciphertext columns encrypted with the
same per-tenant DEK. The `unique_constraint(:user_id)` becomes
`unique_index(:user_id, :name)` plus a partial unique index on
`(user_id) where is_default`. Every existing row is backfilled as that
account's default set, so an account that never opens the feature behaves
exactly as it does today.

Not a vault. A vault is untyped configuration; a credential set is typed, so
`InferenceCredentials.Validator` still pings a provider on save, the console
still reports which providers are present without decrypting, and the
broker's implicit binding to the provider host still attaches. ADR 0052
decision 6 has already set the direction that managed credential material is
not ordinary configuration, and a set is the static half of the same idea.

Three rules follow from "exactly one default", and each of them is a refusal
rather than a silent correction:

- **The first set an account gets is its default**, whoever asked for it. An
  account with no default is an account nothing can read a credential for.
- **The default cannot be deleted.** Promote another first. For an account
  with one set there is nothing to promote and the set stays.
- **A set cannot be demoted**, only replaced. There is no state the partial
  index can hold for "no default", so an API asked for one is refused rather
  than ignored: a client that believes it demoted a set should find out at
  the call, not at the next conversation.

"Has this account connected a provider at all" — the onboarding step and the
dashboard — asks **every** set. An account whose only key lives in a set they
made for one agent has connected one, and putting the nag back in front of
them would be wrong. Everything else that reads without being told which set
reads the default.

### 2. Selection returns a source, not an atom

`select/4` returns `{:ok, %InferenceCredentials.Source{}, creds}` instead of
`{:ok, :own | :platform, creds}`. The source carries `origin`
(`:own` | `:platform`, the billing question, with today's vocabulary intact)
and `scope`, which says where the value came from: `:credential` an
`inference_credentials` row, `:tenant_secret` an environment or vault secret
(decision 5), `:platform` a platform key or the deployment's ChatGPT grant,
`:none` a provider that needs no credential, `:missing` a provider that needs
one where neither the tenant nor the deployment has it. It threads through
`SpriteEnv.select_inference/3`, `ConversationServer` state and the
`TurnMachine` context, and the usage stamp is derived from it rather than
from a bare atom.

The struct carries only what something reads. `set_id` arrives with decision
1, where there is a set to name. **A `kind` field naming the credential atom
that served the turn is deliberately absent**: the runtime picks between an
account's credentials by its own rule — `Managoat.Runtimes.Claude` prefers
`CLAUDE_CODE_OAUTH_TOKEN` and `Managoat.Runtimes.OpenCode` reads only the API
key for the same provider — so a `kind` derived here would state the wrong
credential for an account holding both. It belongs to whichever change first
needs to bill or report per credential, together with a derivation that
matches the runtime.

This is ADR 0052 decision 4's requirement, built once. The grant work adds
`grant_id` and `generation` to the same struct instead of re-cutting the
plumbing, and its rule that token and account metadata come from one scoped
read is unaffected: a set supplies no metadata.

### 3. An agent names a set; a launch may override it

`agents.inference_credential_id` is the agent's set.
`agents.allowed_inference_credential_ids` bounds what a launch may name —
`nil` any tenant set, `[]` none, non-empty an allowlist — the shape
`allowed_vault_ids` and `allowed_environment_ids` already use.
`conversations.inference_credential_id` is the per-launch override, refused at
the door when it is outside the allowlist rather than clamped.

Unset at both levels resolves to the account's default set. That is what every
account has today, so nothing about an existing agent changes.

**This amends ADR 0052 decision 4's "no per-agent preference in the first
version."** That call was made about a rotating grant, where an account holds
one link and switching accounts is reconnect; per-agent selection over a
lifecycle nobody had asked to fork was scope with no demand behind it. A
static API key has no lifecycle to coordinate, and per-agent is the entire
request here. The grant half of 0052 is untouched: an account still links one
ChatGPT subscription, the preference for which source a Codex agent takes
stays user-level, and a set may name a grant only once 0052 decision 4 lands.

### 4. Inference credentials travel in process environment, not on disk

Add the four static credential variable names to
`Conversations.Identity.@process_only`, so `disk_env/1` strips them before
`/home/sprite/.env` is written. Every spawn still receives them through `env:`,
which is how the runtime, its tools and an environment's `setup_script`
already get `FOUNTAIN_TOKEN`. What is lost is `source .env` inside a script
that wants the key in a *later* shell; the variable is in the script's own
environment when Fountain runs it.

This is the change that makes decision 3 safe on a shared sandbox, and it is
worth making on its own: a machine's disk should not hold a credential that
belongs to one conversation on it.

### 5. A tenant secret resolves the source; it does not silently override

When the conversation's merged environment and vault secrets carry a name that
is one of the four static credentials, and the model's provider accepts it,
the source is `:own` with `scope: :tenant_secret`, whether or not a set
supplies one. The gate, the stamp, the pricer and the ceiling then agree with
what the sandbox actually runs on.

The secret is neither reserved nor rejected. Overriding a static key is
documented, live behavior that tenants rely on; what was wrong with it was
that it was invisible, not that it existed. Managed ChatGPT grants keep ADR
0052 decision 6's reservation, because a rotating grant cannot be overridden
without breaking custody. **Reserve what rotates, resolve what is static.**

`PlatformInference.gate/3` runs at `start_conversation` before anything is
provisioned and today receives only the user, the model and the runtime. It
gains the launch's resolved environment and vault so that it asks the question
the provision-time selection answers. Where the two can still disagree — an
environment edited between the door and the provision — the provision wins,
and the door never refuses a turn the provision would have run on the tenant's
own credential.

### 6. A set is not part of sandbox identity

The home identity tuple stays `(user_id, agent_id, environment_id, vault_id)`
(ADR 0023). Decision 4 is what permits this: two conversations on one machine
with different sets differ only in process environment. Putting the set in the
tuple would fork a persistent home per credential, which is the opposite of
what a tenant juggling subscriptions wants — one computer, two subscriptions.

One runtime does not fit. Codex writes an account file into `$CODEX_HOME`, so
two peers with different sources on one machine overwrite each other. ADR 0052
decision 5 already requires separate auth locations for exactly this, and that
requirement is inherited rather than re-solved here: until it lands, a codex
agent whose set differs from another live codex peer's on the same machine is
refused at admission rather than served the wrong account.

### 7. A business with many customers gets principals, not sets

Sets are not a tenancy mechanism and must not become one. ADR 0044 settled
this: a shared service account would make the application re-implement
isolation and billing over one account, and any credential holding it reaches
every customer's machine. A principal is a real `users` row with its own DEK,
its own credential rows and its own audit trail, and
`Principals.billing_subject_id/1` already resolves a claimed principal to its
owner, so the business gets one invoice and per-customer usage attribution.

One gap blocks that path and is closed here: a `principal`-scoped API key
cannot write account state (`RequireFullScope`), so the business cannot set
its customer's credential on the principal it just opened. The owner of a
principal gets an owner-authenticated route to write a credential on a
principal it owns. The principal's own key gains nothing.

## Consequences

Selection stops being a boolean over one row and becomes a resolved source
carried through the conversation lifetime. That is more state, and it is the
state ADR 0052 decision 4 needs anyway; the cost is paid once.

Billing gets more accurate and, for some tenants, cheaper: a tenant running on
a vault-supplied key stops being billed for platform inference and stops
consuming the deployment's daily ceiling. The hosted deployment should expect
platform inference volume to fall by however much of it was this bug.

A credential leaves the shared `.env`. A setup script that re-reads the file
in a later shell to recover a provider key must take it from its own
environment instead. This is a real break for anyone doing that, and the
release note has to say so.

The four static credentials and a managed ChatGPT grant now follow different
rules for the same question, and the rule is stated once as "reserve what
rotates, resolve what is static". Someone will have to be told this twice.

Automatic failover when a subscription is exhausted is **not** part of this.
It needs per-runtime quota-error detection, per-credential cooldown state, and
a mid-turn environment rewrite with an ACP session restart. Static per-agent
assignment is how a tenant with several subscriptions actually divides work,
and it is what ships; the pool is a later decision with evidence behind it.

## Alternatives considered

- **A vault per credential set.** Works today with no code: a vault secret
  overrides the credential, `allowed_vault_ids` bounds it, and a launch names
  it. Rejected because `vault_id` is in the sandbox identity tuple, so it
  forks a persistent home per subscription; because the value is not
  validated, not reported and not visible to the gate; and because a vault
  naming a credential of a different kind puts both `CLAUDE_CODE_OAUTH_TOKEN`
  and `ANTHROPIC_API_KEY` in the environment, which
  `Managoat.Runtimes.Claude.default_env/2` exists to prevent.
- **Reserve the four static names the way ADR 0052 decision 6 reserves the
  managed one.** Consistent, and it breaks a documented behavior tenants use
  today to no benefit: a static key has no custody boundary to protect.
- **A user-level preference only, as ADR 0052 decision 4 has it.** Serves
  neither request. The juggler divides work per project, which is per agent.
- **Teams or sub-accounts.** The reseller's shape, and out of scope until the
  100-weekly-active-user gate. Principals reach the same outcome without
  building tenancy twice.
- **Put the set in the sandbox identity tuple.** Simple and wrong: it gives a
  tenant one persistent home per credential when they asked for one home.
