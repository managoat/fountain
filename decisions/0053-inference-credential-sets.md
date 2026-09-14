---
type: ADR
title: "An account holds several inference credential sets"
description: "Accepted. The #2018 stack (thirteen PRs, #2019 to #2046, merged 2026-09-13) built named sets, source resolution and durable bindings, process-only inputs, and current-owner principal writes. Codex uses an interim machine-lifetime source binding; per-peer auth isolation and managed user execution remain unbuilt."
tags: [inference, billing, security, conversations, accounts]
status: stable
adr: "0053"
adr_status: "Accepted"
date: 2026-09-12
generated: { by: claude-fable/5.1, at: 2026-09-14T07:45:43-04:00 }
verified: { by: claude-fable/5.1, at: 2026-09-14T07:45:43-04:00 }
stale_after: 2026-10-12
---

# 0053 — An account holds several inference credential sets

**Status:** Accepted, 2026-09-14 (#2176 decision 5). The #2018 stack
merged on 2026-09-13 as thirteen PRs: #2019 (this ADR, then Proposed),
#2022, #2023, #2025, #2027, #2028, #2031, #2034, #2042, #2043, #2044, #2045
and #2046. What follows is the built-with-gaps inventory taken against that
stack on 2026-09-13 and re-checked against `main` at `05c18224` on
2026-09-14; acceptance is of the decisions, not evidence of deployment.

The stack built named/default credential rows, agent selection and
launch allowlists, account API/OpenAPI and console management, and
current-owner principal credential writes. Its resolver identifies static
set or environment/vault credentials, including runtime aliases, and carries
the selected source into admission, provisioning and billing. Conversations
persist source identity/revision and the selected set, model, runtime,
environment and vault; turns snapshot the binding. Wake and resume validate
that binding instead of silently selecting today's default. Replaced,
deleted or unusable explicit sources are refused.

Process-only inference inputs include environment/vault overrides and runtime
aliases. Existing-file cleanup is part of the binding repair. Codex uses an
interim atomic machine binding before auth preparation. The sandbox retains
its Codex source identity/revision after conversation termination or deletion;
a different source requires a new sandbox. There is no proven reset path
that clears this binding. Existing machines without a provable binding are
not eligible for a new source. Separate per-peer auth directories required
by decision 6 remain unbuilt. This guard restricts admission while mutable
auth state remains shared.

Plain `env_vars` sources currently use the environment's whole-map revision,
so an unrelated plain-variable edit conservatively invalidates that source.
Before multi-source admission is enabled, every serving node must use the
new source-before-row mutation lock order. Migration triggers preserve the
revision checks but cannot make older writers' lock ordering safe. This is a
rollout constraint, not evidence that a mixed-version fleet is compatible.

The managed execution and user-linking work in ADR 0052 remains unbuilt:
durable broker authorization, issuance/update fences, legacy connection
drain, protected activation, user subscription selection and acceptance
across link/turn/refresh/restart/disconnect are not completed by this stack.
The requirements and release checks below still apply. A successful source
review or test run does not establish rollout, cleanup of a deployed fleet,
or managed-path activation.

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
when this was written, `PlatformInference.gate/3` and `select/4` both asked
`InferenceCredentials.has_own?/2`, which read only the credential row. So on
a deployment that held platform keys the conversation was selected
`:platform`, `TurnMachine.with_inference/2` stamped `"platform"`,
`Workers.CreditPricer` billed the tenant for platform inference, the turn
counted against `PLATFORM_INFERENCE_DAILY_CENTS`, and `check_ceiling/0` could
refuse a later turn — while the tenant's own secret was what actually served
every one of them. This was live on the hosted deployment, which has held
platform keys since 2026-09-03, until #2023 (a tenant secret naming a
credential resolves as `:own`) and #2025 (the door gate asks what the
provision will answer) fixed it on 2026-09-13; `has_own?/2` no longer
exists. #1941 had corrected an adjacent facet on
2026-09-12 (a platform turn is stamped when the deployment holds no
platform API key at all); it did not reach this one, because the stamp was
still derived from a selection that could not see the secret.

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

The initial carrier refactor may preserve today's selection behavior with
only `origin` and `scope`. It is plumbing, not completion of ADR 0052 decision
4. The shared resolver then identifies the credential kind the runtime will
actually use. Claude prefers OAuth while OpenCode's Anthropic path accepts
only an API key; provider eligibility alone cannot identify that source.
Billing and the runtime's auth inputs must derive from the same resolution,
including removal of conflicting inference auth inputs (decision 5).

`scope` describes provenance, not tenant authority. Add `set_id` with named
sets, and owner scope, `grant_id`, `generation` and matching provider-account
metadata with managed grants. Token and account metadata come from one
scoped read/version; bearer material stays in a separate internal credential
object. Never compare bearer strings to infer identity or ownership.

Before allowing different sources in a shared sandbox, persist a non-secret
resolved source reference with the peer and snapshot it for turn accounting.
The reference must distinguish credential replacements within one set or
environment/vault source, not merely identify the containing row. Resume and
reattach recover that binding rather than resolve the account's current
default again. A changed default applies to new selections. A deleted,
ineligible or replaced source cannot silently reroute an existing peer:
require an explicit new selection or reauthentication before another turn.
Normal managed-token refresh preserves the pinned grant generation.

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
tenant-supplied credential does not require Fountain's managed-grant refresh
machinery, and per-agent is the entire request here. Replacement and deletion
still follow decision 2's source-binding rules. The grant half of 0052 is
untouched: an account still links one ChatGPT subscription, the preference
for which source a Codex agent takes
stays user-level, and a set may name a grant only once 0052 decision 4 lands.

### 4. Inference auth inputs leave the shared environment file

Add every supported runtime's inference credential variable name and alias to
`Conversations.Identity.@process_only`, so `disk_env/1` strips them before
`/home/sprite/.env` is written. Four credential columns do not mean four env
names: OpenCode emits `GOOGLE_GENERATIVE_AI_API_KEY` for the same Gemini
credential that the Gemini runtime receives as `GEMINI_API_KEY`. Keep the
resolver's alias inventory and disk filtering consistent with the pinned
runtime adapters, with compatibility coverage for each runtime/provider.
Every spawn still receives its resolved auth inputs through `env:`,
which is how the runtime, its tools and an environment's `setup_script`
already get `FOUNTAIN_TOKEN`. What is lost is `source .env` inside a script
that wants the key in a *later* shell; the variable is in the script's own
environment when Fountain runs it.

This prevents shared-file overwrites and stale credential persistence; it is
not a security boundary between processes able to inspect each other. Audit
runtime-owned auth files and caches before enabling multiple sources on one
machine, and isolate mutable auth state as decision 6 requires. Upgrade and
reuse paths must remove old inference entries from an existing `.env`, not
only omit them when creating a new machine. Principals remain the customer
isolation boundary.

### 5. A tenant secret resolves the source; it does not silently override

Use one runtime-aware resolver for admission, provisioning and usage
attribution. Its precedence is explicit:

1. Resolve the launch's allowed set override, then the agent's set, then the
   account default. Missing or forbidden explicit selections fail; they do
   not become a different set.
2. For a Codex run with a selected user ChatGPT subscription, keep ADR 0052's
   subscription preference and no-fallback rule. Failed runtime/broker or
   grant eligibility checks return an actionable error. Conflicting
   inference auth inputs must not override it during provisioning. Selecting
   an API source requires an explicit preference change.
3. Otherwise combine tenant credentials with the resolved environment/vault
   inputs. Vault wins over environment on the same name; those overrides
   win over the set's value for the same credential kind. Normalize supported
   aliases, reject conflicting values for aliases of one kind within the
   same layer, then apply the runtime's credential-kind precedence. Claude's
   OAuth preference and OpenCode's API-key-only Anthropic path remain intact.
4. Use the existing platform policy only when no tenant source is selected
   or supplied for that runtime/provider. An unusable explicit tenant source
   returns an actionable error instead of silently using platform inference.

When the winning credential comes from environment/vault inputs, the source
is `:own` with `scope: :tenant_secret`. Remove competing inference auth inputs
from the runtime launch so a second variable cannot change authentication
after selection. This filtering targets inference auth for the selected
runtime/provider, not unrelated tool secrets. The gate, usage stamp, pricer,
ceiling and emitted auth inputs all consume that same resolved source.

The secret is neither reserved nor rejected. Overriding a static key is
documented, live behavior that tenants rely on; what was wrong with it was
that it was invisible, not that it existed. Managed ChatGPT grants keep ADR
0052 decision 6's reservation to preserve managed custody. That reservation
also covers static workspace
ChatGPT tokens on the managed path. Rotation is not the boundary:
**protect managed credentials; resolve ordinary tenant overrides.**

Admission at `start_conversation`, before anything is provisioned, calls
`InferenceCredentials.resolve/4` with the launch's environment and vault and
then `PlatformInference.gate_source/1` on the resolved source (#2025), so it
asks the question the provision-time selection answers. Admission checks a
resolved snapshot;
it cannot promise an outcome based on future configuration edits. Before
provisioning writes auth state or starts a peer, validate the source revision
and eligibility again. A changed source requires fresh resolution and all
applicable admission checks before committing a new peer binding. In
particular, a tenant key disappearing after admission cannot select platform
inference without checking platform eligibility and its ceiling. Serialize
the binding with source changes; release database locks before sandbox or
provider I/O. Usage records keep the binding that actually served the turn.

### 6. A set is not part of sandbox identity

The home identity tuple stays `(user_id, agent_id, environment_id, vault_id)`
(ADR 0023). Different sources share the workspace while process environment
and runtime auth state are bound to their respective peers. Putting the set
in the tuple would fork a persistent home per credential, which is the
opposite of what a tenant juggling subscriptions wants — one computer, two
subscriptions.

One runtime does not fit. Codex writes an account file into `$CODEX_HOME`, so
two peers with different sources on one machine overwrite each other. ADR 0052
decision 5 already requires separate auth locations for exactly this, and that
requirement is inherited rather than re-solved here. It covers API-key peers
as well as subscription peers, and preparation, execution, configuration,
skills and resume must use the same per-peer auth location.

Until that isolation lands, an admission guard must compare resolved source
identities and revisions/generations, not set IDs. A key edit, environment
override or grant replacement can change the source without changing the
set. Atomically reserve compatibility on the machine before any auth-file
write, including peers still preparing; two concurrent starts cannot both
observe no live peer and proceed with incompatible sources. Failed starts
must release their reservation. If this cannot be proved, keep multi-source
Codex admission disabled until separate auth locations are available.

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

## Implementation order and acceptance

This is a shared implementation plan for the overlapping parts of ADRs 0052
and 0053, not a second selection stack. The existing grant lifecycle,
encryption, refresh and keepalive PRs (#2011–#2015) and the inactive protected
compiler (#2017) were the prerequisites for managed grants; their tenant-owner
half was deleted in #2188 (#2176 decision 1), so the "User grants" stage below
starts from the platform path alone. Broker releases through 0.14 provide library
capabilities; Fountain's durable authorization and activation remain unbuilt.

| Stage | Deliverable | Required proof before its consumers activate |
|---|---|---|
| Shared selection | Source carrier, effective runtime resolver and env/vault billing fix | OAuth/API conflicts; every runtime alias; set/env/vault precedence; tenant overrides at the platform ceiling; no subscription fallback; source changes between admission and provisioning |
| Shared auth binding | Durable peer/turn source references, process-only inputs, existing-file cleanup and per-peer runtime auth locations | Concurrent incompatible starts; edits within one set; mixed API/subscription peers; preparation and setup scripts; restart, resume and reattach; defaults/deletion without silent source changes |
| Credential sets | Named/default rows, agent default and allowlist, conversation override, API/OpenAPI/SDK and console | Tenant-scoped references; allowlist denial; default migration; replacement/deletion semantics; shared-home compatibility |
| Managed execution | Durable broker source authorization, issuance/update fences, invalidation and legacy connection drain; then protected platform adoption | Disconnect versus issuance/update/admission; stale generations; missed invalidation on existing CONNECT; unavailable store denies; pinned client compatibility |
| User grants | Subscription selection consuming the shared resolver, durable linking attempts/settings/API, accounting and controlled acceptance | Scoped token/account pair; cancellation/reconnect/deletion races; no platform debit for user inference; real link/turn/refresh/restart/disconnect evidence |
| Principal management | Owner-authenticated credential writes for an owned principal, contracts and docs | Foreign-principal denial; no new rights for principal-scoped keys; owner billing attribution |

Build shared selection before its feature consumers. Shared auth binding is
required before multi-source execution; schema/API slices may be reviewed
earlier without enabling that behavior. Managed broker authorization and
draining can proceed independently of the selection refactor. User linking
depends on the shared selection/auth contract and protected managed execution,
not on the entire credential-set console or principal-management stack.

Keep PRs bounded by these contracts and their consumers. Tests should force
configuration and lifecycle races with barriers, not rely on timing. This
sequence does not authorize activation: a release plan must separately cover
data preflight, existing `.env` cleanup, compatible serving nodes, legacy
socket drain, rollout evidence and rollback. User linking remains disabled
until the managed path meets ADR 0052's acceptance requirements.

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

Ordinary tenant credentials retain configurable overrides. Managed ChatGPT
credentials, including static workspace tokens, retain protected custody.
Both paths use the same source resolver and billing attribution contract.

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
  today to no benefit: these ordinary tenant credentials do not enter the
  managed ChatGPT custody path merely because they supply inference.
- **A user-level preference only, as ADR 0052 decision 4 has it.** Serves
  neither request. The juggler divides work per project, which is per agent.
- **Teams or sub-accounts.** The reseller's shape, and out of scope until the
  100-weekly-active-user gate. Principals reach the same outcome without
  building tenancy twice.
- **Put the set in the sandbox identity tuple.** Simple and wrong: it gives a
  tenant one persistent home per credential when they asked for one home.
