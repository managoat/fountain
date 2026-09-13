---
type: ADR
title: "Egress credential brokerage: the sandbox holds placeholders, the broker holds the credential"
description: "Accepted; live in production for every tenant since the 2026-09-04 flip, served by Fountain's own proxy since 2026-09-03. Outbound HTTP credentials are attached at a forward proxy the sandbox reaches over HTTPS_PROXY, so the agent process holds only placeholders and the only host it may reach is the broker. Gate 0 passed on 2026-08-24 against a real sandbox: brokered API calls and a private clone with no credential in the sandbox, cross-tenant probe refused, +258ms per request."
tags: [security, secrets, sandbox, egress, governance]
status: draft
adr: "0019"
adr_status: "Accepted"
date: 2026-08-14
generated: { by: human:jhgaylor, at: 2026-08-14T04:45:00-04:00 }
verified: { by: codex, at: 2026-09-12T00:00:00-04:00 }
stale_after: 2027-03-03
---

# 0019 — Egress credential brokerage

**Status:** Accepted — **live in production for every tenant, on Fountain's own proxy.**
`Fountain.Broker` and the provisioning wiring exist on `main` (#1090 PRs 1–3),
behind `BROKER_LISTEN_PORT`: blank, and every conversation provisions exactly
as it did before the module existed; set, and every tenant of the deployment
is brokered. The proxy is `Managoat.Broker`, run inside the
Fountain pods and published at `broker.inevitable.fyi` by the Traefik TCP
router of §11. It was a vendor
service, Agent Vault, until the flip of 2026-09-03; see the amendment. Its done-when was observed on a production
Sprites conversation the same day — see *Gate 1a* under *Gates*. Every gate is built: 1a and 1b (placeholders, bindings), 2 (`limited` at the
broker), 3 (inference credentials) and 4 (the egress trail). #1090 is closed and each
later gate gets its own tracker.

The ratchet of §9 ran its course and is **retired** (amendment of
2026-09-12). The hosted deployment named **one** tenant, the maintainer's own
account, from home-cloud#131 (2026-08-25) until home-cloud#163 (2026-09-04),
which set `BROKER_TENANTS` to `*` and brokers every account. `*` was the
wildcard #1553 added for exactly this end state, and the code that read a
tenant list is gone.
The reason to widen was gate 3 rather than tenant secrets: platform inference
credentials reach every conversation, while at the time of the flip every
brokerable tenant secret in the deployment belonged to the maintainer and
`secret_bindings` was empty.

**One consequence of the floor, worth stating plainly.** A provider that
cannot enforce `allow: [broker]` cannot host a brokered conversation, so under
`*` a self-hosted runner (`managoat_runner`, capabilities `[:suspend,
:attach]`) refuses with `{:broker, :backend_lacks_network_policy}`.
`BROKER_ALLOW_UNENFORCED` makes that advisory and is a development escape
hatch. Reattach now checks provider support and applies the current floor
before refreshing credentials or resuming a session. A policy failure stops
the wake for retry and does not retire the sandbox. Removing a tenant from
brokering reapplies a `limited` environment, but an unrestricted environment
is a no-op: it does not clear an existing floor. Reprovision that machine
when removing brokering; the current sandbox policy API has no reset operation.

**Revised 2026-08-25 (gate 1a).** Building it changed three things below,
each marked in place: §11 is a vault per *conversation*, not per tenant; the
proxy URL in *Gates* is the broker's own listener, not Traefik's front; and the
CA goes through `sudo` because the trust directory is root-owned.

**Revised 2026-08-24.** The four questions the first draft left open are
answered: the vendor (§8), whether brokering is a tenant-facing option (§9),
whether the broker may read request bodies (§10), and where it runs (§11). The
production numbers are refreshed below, and a new Context subsection records
what [0023](0023-persistent-agent-sandbox.md) — which shipped on 2026-08-24,
after this draft — changed underneath it.

**Gate 0 passed on 2026-08-24**, against a real Sprites sandbox provisioned by
production Fountain. What it proved, what it cost and what it found is in
*Gates* below; nothing in the product changed, so at that date the rest of this ADR described behavior not yet built. The spike ran entirely on configuration
already available to a tenant — an environment, a `limited` network policy and
a setup script — which is why it needed no code and why its results are about
the mechanism rather than about our implementation of it.

**Source verification, 2026-09-05.** Checked the server, its pinned
`managoat_broker` 0.11.0 source, and the wake/Connections changes in this
revision. This is an agent review of code, not a new production smoke test.
Production counts, hostnames, latency measurements and dated rollout records
below retain their original observation dates.

| Section | Verdict | What the source implements |
|---|---|---|
| §1 Storage and delivery | Built, narrower than the original headline | `Broker.split/2` and `Egress` broker enabled bindings, the GitHub defaults, runtime inference credentials and active connection tokens. Other encrypted secrets still enter the sandbox as values. `Crypto` remains the storage boundary. |
| §2 Network floor | Built, with a development exception | `Provisioning.check_broker_support/4` and `Egress.apply_policy/4` cover cold provision, warm restore and reattach. `BROKER_ALLOW_UNENFORCED` explicitly permits unsupported providers without enforcement. |
| §3 Environment policy | Built | `Broker.network_for/1` creates passthrough rules plus default deny for `limited`; unrestricted uses unmatched-host passthrough behind the same sandbox floor. |
| §4 Placeholders | Built | `Broker.placeholder/1` and `Native` construct the placeholder and matching substitution rules together; inference uses vendor-shaped placeholders. |
| §5 Conversation scope | Built | `Native.Sessions` stores a token hash, conversation and user ids, expiry and DEK-encrypted rules. The proxy resolves credentials through that store. |
| §6 Failure behavior | Built, with limits stated here | No plaintext fallback on broker failure. A failed wake preserves the disk. CA installation on reattach remains best effort; a failure is logged and may fail the next turn. |
| §7 Non-HTTP labels | Not built | No `unbrokerable` field or classification UI/API exists. Non-HTTP credentials remain a residual plaintext delivery path. |
| §8 Vendor | Changed | `Native` is the only backend. The Agent Vault client and its configuration were removed; the original vendor comparison is historical. |
| §9 Rollout and escape hatch | Built, and the ratchet retired | Brokerage is a property of the deployment alone: `Broker.configured?/0` is the whole gate, and `Broker.enabled_for?/1` and the `:broker_tenants` configuration no longer exist. The proposed per-secret classification escape hatch is not implemented. Connections and binding management additionally require the `connections` rollout flag; that flag does not disable brokering. |
| §10 Bodies and rewriting | Partly built by design | The proxy sees HTTP bodies but streams them without substitution. `Injector` substitutes header values and request targets. Content-policy rewriting remains future work. |
| §11 Topology and custody | Changed | Fountain runs the library listener in-process, stores sessions in its own database and derives the CA from the master key. There are no vendor vaults or separate broker database. |

The egress trail is implemented by `Native.handle_request/4`, `RequestLog`
and `BrokerReaper`: terminal request events carry status, total latency and
errors, while passthrough is distinguished from credential injection by
`scheme`. The pinned proxy also keeps an authentication challenge connection
open for bounded retries; the original 407 regression is historical.

This ADR implements and generalises **[0016](0016-governance-as-an-acp-proxy.md)
§4** (*credential brokerage: the sandbox holds no long-lived secret*), and
concretises the first bullet of its §5 conformance bar (*network egress policy,
expressible per conversation*). It does not supersede 0016. It changes 0016 in
one specific way: **0016 gate 3 is no longer blocked on the base-URL survey**,
because the mechanism chosen here does not need one.

It is also the only governance control on the table with **no dependency on
ACP**. 0014, 0015 and 0016 are a sequence; this is not part of it, and can be
built while that sequence is still being argued about.

## Context

This section records the problem and measurements from August 2026, before
the implementation. Its plaintext-delivery and unused-policy descriptions
are historical; the verification table above describes current behavior.

### The sandbox holds every secret, and by default it may reach anything

Two facts compose badly.

**Secrets arrive as plaintext.** `merge_secrets/3`
(`conversation_server.ex:970`) decrypts the environment's and the vault's
secrets with the tenant DEK and merges them; `do_build_sprite_env/4`
(`conversation_server.ex:938`) appends the merged map to the sprite's
environment verbatim. `Fountain.Conversations.Redaction`'s moduledoc records
that they also land in `/home/sprite/.env`, so there is a second copy on disk
that outlives any single process.

**Egress is open unless a tenant says otherwise.** `networking_type` defaults to
`"unrestricted"` (`environment.ex:29`), and `unrestricted` is a no-op —
`apply_network_policy(_handle, %Environment{networking_type: "unrestricted"}, _)`
returns `:ok` without calling the sandbox (`provisioning.ex:271`). A conversation
with no environment at all takes the `nil` clause and is equally unpoliced.

So the normal shape of a Fountain conversation is: a process running untrusted
model output, holding every credential its tenant configured, on a host that can
open a connection to anywhere. A prompt injection does not need a clever exploit
chain; it needs `curl`.

### The control exists, is well designed, and has never once been used

This is the fact that should decide the ADR. Production, measured twice:

| | 2026-08-14 | 2026-08-24 |
|---|---|---|
| Environments with `networking_type = 'limited'` | **0** | **0** |
| Environments with `networking_type = 'unrestricted'` | **20** | **36** |
| Environment secrets (`secrets`) | 56 | 79 |
| Vault secrets (`vault_secrets`) | 22 | 50 |
| Inference credentials | 3 | 6 |
| **Plaintext credentials reaching sandboxes** | **78** | **135** |

Ten days, no change in posture, 73% more exposure. The second column is the
argument the first one only implied.

Two further facts from the same query, neither of which the first draft had,
and both of which make the work smaller than it reads:

- **Two tenants hold every one of those secrets** (of 128 accounts). The
  migration in gates 1 and 2 is a two-tenant migration, one of which is ours.
- **Roughly half of what is stored is not a credential.** Grouping the 129
  environment and vault secrets by key name: 73 are token-shaped
  (`GITHUB_TOKEN` ×31, `RENDER_API_KEY` ×11, `POSTHOG_API_KEY` ×11,
  `HONEYCOMB_API_KEY` ×11, `GH_TOKEN` ×4, `CLOUDFLARE_API_TOKEN`, …), 9 are
  URLs or DSNs, and 40 are not secrets at all (`GIT_AUTHOR_NAME`,
  `BUZZ_RELAY_URL`, `AGENT_APPS_PROJECT_ID`). The classification §7 demands is
  therefore load-bearing rather than ceremonial: a scheme that assumes every
  row in `secrets` is a brokerable HTTP credential is wrong about a third of
  them.

One of those keys is worth naming, because it is the shape of the residual gap
and it is ours: `BUZZ_PRIVATE_KEY` (×6) signs Nostr events inside the process
and talks to a relay over a WebSocket. No header-injecting proxy can broker
it, at any point in the future. It is not an edge case to be closed later; it
is the class §7 says must be labelled.

`NetworkPolicy` is a good piece of design — intent-level, default-deny, with
`allow: []` meaning deny-all and the Sprites fail-open-on-empty quirk absorbed by
the adapter rather than the caller (`network_policy.ex`, and all three providers
advertise `:network_policy` since [0018](0018-sandbox-provider-abstraction.md)).
It has 78 tenant secrets riding past it and has protected none of them, because
using it requires a tenant to know it exists, choose `limited`, and then enumerate
every host their agent will ever need.

**A safety default that requires configuration is not a safety default.** The
lesson is not that tenants are careless; it is that we put the burden in the
wrong place. Any fix that leaves the safe posture opt-in will produce the same
table a year from now.

### `Redaction` is the current mitigation, and it is the wrong shape for this

`Fountain.Conversations.Redaction` scrubs secret values (≥8 bytes) out of log
events at the single write path, deliberately via an ETS registry rather than a
caller-supplied argument, because "redaction a caller has to remember will
eventually be forgotten by a new caller." That reasoning is sound and the module
should stay.

But it protects **the transcript**, not the credential. It stops a secret being
written into Postgres by `env` or `set -x`; it does nothing about a secret sent
over a socket, which is the path that actually matters. Today it is the only
thing standing between a printed credential and a permanent unencrypted copy —
which tells you how much of our secret handling is downstream damage control.

### 0016 §4 named this, and picked a mechanism that does not generalise

0016 §4 states the problem exactly: *"we hand the key to the thing we are
governing, and every control above is theatre once the agent can exfiltrate it
and use it elsewhere."* Its proposed shape is a broker reached by pointing the
runtime's **provider base URL** at Fountain, and it flags the open question:
whether every runtime honours a base-URL override, and whether that is stable
across their point releases.

Two problems with that mechanism, and neither is fatal to 0016's goal — only to
its means:

- **It only reaches inference.** A base-URL override redirects the model API and
  nothing else. Of the 78 tenant secrets above, 3 are inference credentials. The
  other 75 — GitHub tokens, deploy keys, database URLs, third-party API keys —
  are exactly the ones a tenant would most mind leaking, and a base-URL override
  cannot touch them.
- **It depends on each runtime's config surface**, which is why the survey is a
  blocker at all. Four runtimes, each with its own override mechanism, each free
  to change it in a point release.

### What a forward proxy changes

[Agent Vault](https://github.com/Infisical/agent-vault) (Infisical) is a
TLS-intercepting, credential-injecting forward proxy built for this exact
problem. Management API on 14321, proxy on 14322 handling both HTTP
forward-proxy and HTTPS `CONNECT`. The agent points `HTTPS_PROXY` at it and holds
only **placeholder** values (`__anthropic_api_key__`); the real credential is
attached to the outbound request at the proxy. Egress filtering is per agent →
service → endpoint, with `unmatched_host_policy=deny` for strict mode. It logs
authenticated traffic, and ships a TypeScript SDK for minting short-lived tokens
for ephemeral sandboxes — which is precisely our per-conversation sandbox shape.

The mechanism difference is the whole argument: `HTTPS_PROXY` is honoured by the
**HTTP client stack**, not by the application's config surface. It covers every
runtime, every CLI, every MCP server, and every `curl` in a `setup_script`,
without asking any of them to cooperate and without a per-runtime survey.

### 0023 landed underneath this draft

[0023](0023-persistent-agent-sandbox.md) shipped on 2026-08-24: one sandbox can
serve many conversations of an agent, turns can run concurrently on it, and a
parked home is checkpointed. This draft was written against a 1:1 world and
four of its assumptions need restating rather than reinterpreting.

- **§5's "the token is scoped to the Conversation" still holds, and is now the
  only shape that works.** The env is not baked into the machine: each
  `ConversationServer` builds its own `sprite_env` and passes it on every
  `exec` and `spawn` (`conversation_server.ex:1255`), so one machine can carry
  two conversations with two different broker sessions. A token minted per
  *sandbox* would make the proxy's request log unattributable the moment two
  conversations share a machine, which is now the normal case.
- **The session token must never reach the disk.**
  `Fountain.Conversations.Identity.disk_env/1` strips the per-conversation
  pairs before `/home/sprite/.env` is written, precisely because that file is
  shared by every conversation on the machine. The broker session token joins
  `@process_only` next to `FOUNTAIN_TOKEN`. Miss that one line and conversation
  A can read B's token off the disk and spend B's credentials, which is a
  worse failure than the one this ADR set out to fix.
- **A checkpoint outlives the conversation.** Placeholders in a checkpointed
  home are harmless, which is the win. A broker session token in one is a
  credential that survives a park; session TTL must be shorter than a park, and
  a wake must re-mint rather than reuse.
- **`Claude.fall_back_to_api_key/2` is a second injection site**
  (`conversation_server.ex:1819`). It puts a real API key into the sprite env
  *mid-conversation*, after `build_sprite_env` has run. Gate 3 has to cover it
  or the fallback quietly reintroduces the plaintext this ADR removes.

## Decision

**Adopt an egress credential broker: the sandbox receives placeholders and a
proxy address for brokerable HTTP credentials, and the only host it may reach
is the broker. Non-HTTP and otherwise unbound secrets remain exceptions.**

The capability is the decision; the vendor is an implementation choice. Agent
Vault was the first implementation. The September amendments record its
replacement by `Managoat.Broker`; §8 retains the original rationale.

### 1. Placeholders replace plaintext in the sprite environment

`merge_secrets/3` stops feeding raw values into `do_build_sprite_env/4` for any
secret designated an outbound HTTP credential. The sandbox env carries
`GITHUB_TOKEN=__github_token__`; the real value is loaded into the broker,
server-side, from the same DEK-encrypted storage it lives in today.

**Envelope encryption is unchanged.** `Fountain.Crypto`, the per-tenant DEK and
the `secrets`/`vault_secrets` tables stay exactly as they are — they remain the
system of record the broker is loaded *from*. What changes is custody at the far
end, not storage at ours.

### 2. The network floor is `allow: [broker]`, and it is not optional

Every brokered conversation gets `%NetworkPolicy{allow: [broker_host]}`. Not a
default a tenant may widen — a floor. This is the half of the design that makes
the other half true: placeholders are worthless to an attacker only if the
attacker also cannot reach an arbitrary host to try them against.

Because all three providers advertise `:network_policy`, this is portable. A
provider that could not express egress policy could not host a brokered
conversation, which is 0016 §5's conformance bar applied for the first time
rather than merely stated.

### 3. `networking_type` changes meaning, and `unrestricted` stops meaning "no policy"

Before brokering: `unrestricted` → no sandbox call at all; `limited` → allowlist from
`networking_config.allowed_hosts`.

Under this ADR both are enforced at the broker, and the sandbox floor is
identical in both cases:

- **`unrestricted`** — the sandbox still reaches only the broker; the broker's
  `unmatched_host_policy` is permissive, so the agent may reach any host but only
  ever with the credentials it was granted. The name stays honest: unrestricted
  *reach*, brokered *credentials*.
- **`limited`** — `allowed_hosts` is translated into broker service rules and
  `unmatched_host_policy=deny`. Tenant intent is preserved; enforcement moves up
  a layer and gains per-endpoint granularity it never had.

**This is a semantic change to an existing field, not an addition**, and it is
the part most likely to be got wrong under time pressure. The migration is
tractable only because the answer to "how many tenants depend on today's
`limited` behaviour" is zero.

### 4. The placeholder name is a contract

Fountain emits placeholder names; the broker recognises them. That agreement is
an interface between two systems with separate deploy cycles, and it must be
versioned and tested as one — not derived independently on each side from a
secret's key name. A placeholder Fountain emits and the broker does not know
produces an outbound request carrying a literal `__github_token__`, which fails
in a way that looks like an application bug rather than a config drift.

### 5. The broker token is scoped to the Conversation

The per-sandbox token is minted at provision time and scoped to the Conversation
— the same term every door already resolves to. This is what lets the broker's
request log join the audit trail from [0013](0013-audit-trail.md): the trail
records *intent* (which actor, which conversation, what changed), the broker
records *effect* (what actually left, to which host, with which credential), and
the Conversation id is the only thing that can join them. A broker token not
scoped to a Conversation buys custody and forfeits the audit story.

### 6. Fail closed

The broker is on the critical path (see *Consequences*). When it is unreachable,
provisioning fails and the conversation does not start. We do not fall back to
injecting plaintext, and we do not start a sandbox with no egress policy. A
governance control with a fallback that disables it is not a control — 0016 makes
the same argument about escalation timeouts, and this is the same rule applied to
infrastructure.

### 7. Non-HTTP egress stays out of scope, and must be labelled

A MITM **HTTP** proxy brokers HTTP. It does not broker `git+ssh`, raw TCP, or
anything else. Repository clones over SSH with a deploy key remain a plaintext
long-lived credential inside the sandbox, and `provisioning.ex` has an SSH path.

This is a real residual gap, not a rounding error, and 0016 §2's corollary
applies unchanged: **a credential that cannot be brokered must be labelled
unbrokered in the UI and the API**, rather than quietly counted under a claim
that covers it. **This labeling requirement is not implemented:** neither
secret schema has an `unbrokerable` field, and there is no classification
control in the UI or API. The honest version of the pitch is "outbound HTTP credentials are
brokered", and the product surface should say exactly that.

### 8. The vendor is Agent Vault, and the interface is ours

Historical decision, replaced by the September 2026 amendments. The server
now runs `Managoat.Broker`; the comparison below explains the first choice.

Decided 2026-08-24. Infisical's commercial successor, **Agent Proxy**, reached
GA in July 2026, free on every plan, with 30-odd service presets. It is the
better-supported product and it is the wrong one for us, for a structural
reason rather than a maturity one: Agent Proxy is stateless and **fetches the
credential back from an Infisical project**, so adopting it means mirroring
every tenant secret into a second custodian's control plane and making their
API a hard dependency of provisioning. Agent Vault keeps its own encrypted
store, which we load from the DEK-encrypted tables that stay the system of
record (§1).

So: **run the open-source preview, behind an interface we own.** Concretely,
one `Fountain.Broker` module with the Agent Vault client inside it and the
seam documented — not a behaviour plus a registry. [0018](0018-sandbox-provider-abstraction.md)
earned its abstraction by having three providers; this has one, and the
abstraction is worth building on the day there is a second.

The preview's API is "subject to change" and that cost is accepted knowingly:
the pin is ours to hold, and the alternative moves custody rather than risk.
Agent Vault's own posture is reassuring where it counts — credentials are
AES-256-GCM under a KEK/DEK wrap, the root CA private key is encrypted with the
same DEK, and the sandbox's session token travels as `Proxy-Authorization`, a
hop-by-hop header that never reaches the origin.

### 9. Brokering is a property of the deployment and of the secret, not a tenant setting

Decided 2026-08-24. There is no per-environment "broker this" toggle.

The cost of an opt-in is not the boolean; it is that every secret-touching path
carries two shapes forever, and that the safe one is the one nobody selects.
That is the table in *Context* — a well-designed control, opt-in, at zero
adoption. Repeating it with a second flag would be a deliberate repetition of a
known failure.

Two knobs do the work instead, and neither is a new product surface:

- **Deployment.** A broker is configured or it is not. Self-hosters need that
  switch regardless (see *Consequences*), and it is the honest place for it:
  an instance either brokers or it says plainly that it does not.
- **Secret.** Delivery currently follows enabled bindings, catalog defaults,
  inference rules and connection rules. The explicit brokerable/unbrokerable
  classification proposed in §7 is still unbuilt.

Rollout **was** an operator ratchet, not an option: a per-tenant enable we
held, flipped tenant by tenant as classification was proven. With two tenants
holding secrets, that ratchet was short, and it is now retired. See the
amendment of 2026-09-12: the deployment switch is the only one left.

**The proposed classification escape hatch is not implemented.** A tenant
cannot mark a secret `unbrokerable` in the UI or API. Secrets outside the
binding/catalog/inference/connection rules still enter the sandbox in the
clear, but this is delivery behavior, not an explicit classification the
product records. Do not describe it as a supported labeling control.

There is a second, blunter path, and it should be described rather than
advertised: `environments.env_vars` is an ordinary map column and is injected
verbatim, so a value put there reaches the sandbox untouched by any of this. It
is the right home for configuration and the wrong home for a credential, for a
reason that has nothing to do with brokering — unlike `secrets` and
`vault_secrets` it is **not encrypted at rest**. A tenant who moves a token
there to dodge the proxy trades a brokered credential for a plaintext row in
Postgres. `Redaction` still scrubs it from the transcript; nothing else about it
improves.

The implemented rule is: **encrypted storage does not imply brokered
delivery. Only credentials selected by the broker rules are brokered.** Environment secrets and vault secrets are
the same case here; the Vault primitive's override semantics (vault wins on key
collision) are unchanged, since brokering happens after the merge.

### 10. The broker may read request bodies, and rewriting is not its job yet

Decided 2026-08-24. TLS interception means the broker sees plaintext prompts and
responses; that is accepted deliberately, not tolerated, because content
inspection and eventual rewriting of what goes to and comes back from a model
is wanted product behaviour.

What does **not** follow is that the egress proxy is where rewriting should
happen. At the proxy, model traffic is bytes: four provider dialects, SSE
frames, tool-call deltas, prompt caching, compression. At the ACP seam
([0016](0016-governance-as-an-acp-proxy.md)) the same content is already parsed
into a structure Fountain defined. Rewriting belongs where the meaning is.

The split, then:

- **ACP-borne model traffic** — rewritten at the seam, when 0016 gets there.
- **Everything else** — an MCP server calling a model directly, an agent's own
  `curl` — is invisible to the seam, and is where a Fountain-owned content
  proxy would eventually sit. Chained, not merged: sandbox → Fountain content
  proxy (our CA, sees bodies, holds no credential) → Agent Vault (attaches the
  credential) → origin. Agent Vault accepts absolute-form HTTP, so the inner
  hop need not be intercepted twice.

None of that is in scope for gates 0–4. It is recorded here so the topology
chosen in §11 does not foreclose it, and gate 0 proves the chain is possible
rather than assuming it.

### 11. One instance, one vault per conversation

The vault and management-port details below describe Agent Vault in August
2026. Current custody is one conversation-scoped session in Fountain’s own
database, with the native listener inside each application replica. There is
no separate vendor store; the deployment history is in the amendments.

Decided 2026-08-24 as a vault per tenant; **amended 2026-08-25, on building
gate 1a, to a vault per conversation** (`c-<conversation id>`, created at
provision, deleted when the conversation ends). Two facts forced it. A tenant
who runs two conversations at once with different `GITHUB_TOKEN`s — the
vault-per-launch identity swap the Vault primitive exists for — would load
both into one broker vault under one key, and the last write would win for
both conversations. And the broker's request log attributes a request to a
user or agent token, never to a session token: `actor_type` and `actor_id`
are empty for every vault-scoped session, so a per-tenant vault could never
answer gate 4's "which conversation sent this". The vault name is the join.

The tenant-level guarantee this section cared about is unchanged: a session
is bound to one vault by the token, so no session can read or broker another
vault, another conversation's or another tenant's. What follows still holds.

A single Agent Vault instance serves every tenant, with a session in the
`proxy` vault role per conversation.
Agent Vault's permission model is two independent axes — instance roles
(`owner` / `member` / `no-access`) and vault roles (`admin` / `member` /
`proxy`) — a token scoped to one vault cannot read another, and `proxy` is
exactly "may broker requests, may not read credentials". The streams do not
cross by construction rather than by our discipline.

Three things follow that gate 0 has to hold, not hope:

- **The vault binding must be on the token, not the header.** Agents select a
  vault with `X-Vault`. A session token that honours a header naming someone
  else's vault is a cross-tenant read, so the probe is explicit: take a valid
  session for tenant A, ask for tenant B's vault, require a refusal.
- **The proxy port has to be reachable from third-party sandboxes**, and Agent
  Vault's own guidance is to keep it on a trusted or private network. Our
  sandboxes run on Sprites, E2B and Daytona, so it needs a public address.
  **Not the Cloudflare tunnel** — that was this ADR's first answer and gate 0
  disproved it: an HTTP forward proxy speaks `CONNECT`, which the tunnel does
  not forward. What works, and is what the spike ran on, is a Traefik
  `IngressRouteTCP` matching `HostSNI` with TLS terminated at Traefik on the
  existing `websecure` entrypoint, forwarding plain TCP to the proxy. The
  sandbox then uses an *HTTPS* proxy (`https://…@host:443`), so the hop that
  carries the session token is encrypted rather than clear. The management
  port (14321) is not exposed at all.
- **We cannot co-locate with the sandbox**, which is the deployment Agent Vault
  recommends for latency. Measured at gate 0: **+258 ms per request** —
  0.356s brokered against 0.098s direct from a control sandbox, with about
  150 ms of that being the sandbox-to-broker leg alone. That is the price of
  the broker living in one place and the sandboxes living in another, and the
  self-hosted runner ([0022](0022-self-hosted-runner-provider.md)) is the one
  topology where co-location is available.

One instance holding every tenant's credentials and seeing every prompt is a
large blast radius, and it is not a new one: the app server already holds the
master key and decrypts all of it. Saying so plainly is better than pretending
a second instance per tenant would be operated as carefully.

## Consequences

**A new hard dependency on the provisioning path of every conversation.** Broker
down means no conversation starts anywhere. Today's failure domains are Postgres
and one sandbox provider; this adds a third, and §6 deliberately makes it
fail-closed rather than degrade. That needs an HA story and a monitored SLO
before gate 1, not after.

**The broker can read everything, and that is now a chosen capability.** TLS
interception means plaintext request bodies — every prompt sent to a model API
and every diff sent to GitHub. §10 accepts this rather than merely tolerating
it, because content inspection is wanted. It belongs in the security posture
docs and in any DPA regardless, and it raises the bar on where the broker runs
(§11) and who can read its logs. The honest framing for a customer is that the
broker sees what a proxy sees; a claim that it does not would be false the day
we ship it.

**Latency on every outbound request**, paid by the agent rather than by a tool
call. Distinct from 0016's PDP latency, which lands per tool call; these
compound if both ship. A number belongs in gate 0's success criteria.

**`Redaction` becomes defence in depth instead of the front line** — and should
be kept exactly as it is. Placeholders in the environment mean the values it
registers are mostly worthless, which is the point; the ≥8-byte floor and the
single-write-path design are still correct for everything that is not brokered.

**A metering and model-policy position falls out for free.** 0016 §4 wanted the
inference broker for two reasons — custody and a usage-based revenue line. A
proxy that sees every request to `api.anthropic.com` can meter and can enforce
model choice. This ADR does not decide to do either; it notes that adopting it
does not forfeit them, which was 0016's worry.

**Self-hosters enable another listener in Fountain.** The native broker
shares the application database and runs in-process. A separately operated
service and database were requirements of the retired vendor deployment. §9 resolves the tension by putting the
switch at the deployment: an instance with no broker configured keeps today's
behaviour and says so, and one with a broker brokers everything classified
brokerable. What is not on offer is a per-environment toggle that lets a
brokered instance run unbrokered conversations quietly.

**0008's economics are untouched.** [0008](0008-byo-inference-credentials.md) is
still the tenant's key and still the tenant's bill; only custody moves, exactly as
0016 §4 argued.

**We would be claiming something buyers check.** "The agent never holds your
credentials" is verifiable by a customer in about five minutes, which is the
point of saying it — and also means an unbrokered path we failed to label is a
found defect rather than a missing feature.

## Gates

These are the original acceptance gates and dated evidence from their
implementation. Vendor commands and initial measurements are historical.

**Gate 0 — passed 2026-08-24.** Agent Vault deployed in the home cloud
(`agent-vault` namespace, SQLite on a volume, telemetry off — it defaults on),
published at `broker.inevitable.fyi` by the Traefik TCP router in §11. Two
vaults, `tenant-a` and `tenant-b`, a `proxy`-role session per sandbox, and
`unmatched_host_policy=deny` set explicitly, because **the default is
`passthrough`** and there is no CLI flag for it — only
`PATCH /v1/vaults/{name}/settings`.

The whole gate ran on configuration a tenant already has: an environment
carrying the proxy variables and a placeholder, `networking_type: limited`
with the broker as the single allowed host, and a setup script as the probe.
No Fountain code changed, which is why these results describe the mechanism
rather than our implementation of it. It was also the **first `limited`
environment this deployment has ever had**, so `apply_network_policy/3` ran in
production for the first time.

| | result |
|---|---|
| brokered call | `api.github.com/user` → 200 as the real account, and a **private repository cloned** over HTTPS, from a sandbox that held no credential |
| no credential in the sandbox | `GITHUB_TOKEN` is 16 bytes beginning `__g`; `/home/sprite/.env` carries the placeholder |
| unmatched host | `example.com` → 403 at the broker |
| cross-tenant probe | tenant-b's session, with `X-Vault: tenant-a` spoofed, → 403. The vault binding is on the token, not the header |
| latency | **+258 ms** per request (0.356s brokered, 0.098s direct from a control sandbox) |
| provisioning cost | **≤170 ms** to mint a session, including exec overhead |
| broker killed mid-turn | fails closed, and reports the wrong thing — see below |
| chained hop | absolute-form HTTP through the proxy → 200, so §10's content proxy can sit in front without a second interception |

Four findings that change the work rather than confirming it:

- **The proxy URL carries both userinfo fields, and both are load-bearing.**
  With only the token, curl works and **git prompts for a *proxy* password and
  aborts** — an error naming the broker, not the repository, which is the sort
  of thing that costs an afternoon. Gate 1a builds it as
  `http://<session-token>:<vault>@host:port` (corrected 2026-08-25: gate 0's
  `https://…@host:443` was the Traefik front in §11; the broker's own listener
  is plain HTTP, and the sandbox trusts its CA for the intercepted upstream).
- **The CA belongs in the operating system trust store, not in per-tool
  variables.** One `update-ca-certificates` satisfied curl, git and npm at
  once (gate 1a adds `NODE_EXTRA_CA_CERTS` for Node, which reads its own
  bundle, and writes the PEM to `/tmp` first: the trust directory is
  root-owned, so it is `sudo install`ed there the way apt is reached). The variable route is worse than useless when a path is wrong:
  `CURL_CA_BUNDLE` pointing at a missing file makes curl fail with no
  fallback, and `NODE_EXTRA_CA_CERTS` alone left npm on "unable to verify the
  first certificate".
- **Deny-by-default finds egress nobody had enumerated.** Provisioning needs
  `registry.npmjs.org` in the vault or the ACP adapter never installs, and the
  turn then failed with `Forbidden: No broker service matching host
  "opencode.ai:443"` — opencode routes model traffic through its own gateway
  rather than the provider's API. Gate 3 is therefore not only about inference
  credentials: every runtime brings its own hosts, and the broker is the thing
  that makes them visible.
- **Fail-closed happens, and says the wrong thing.** With the broker scaled to
  zero every call returned 000, the setup stage still reported `exit_code: 0`
  and `done`, and the conversation died at `{:opencode_install_exit, 1}`.
  Nothing anywhere said "broker unreachable". §6 is satisfied by accident
  today; gate 1 owes it a preflight.

Two things this ADR argued from reading the code are now observed: the session
token does reach the shared `/home/sprite/.env`, and `Redaction` scrubs the
placeholder along with everything else, so probes have to print lengths rather
than values.

**Gate 1a — built and flipped for one tenant, 2026-08-25 (#1090, closed).**
The narrower slice #1090 argued for: catalog bindings only (`GITHUB_TOKEN` /
`GH_TOKEN` to `api.github.com` as a bearer and to `github.com` as basic
`x-access-token`), one operator-held tenant list, no schema change. Verified
end to end against a real Agent Vault and a Linux runner with no cloud in the
loop: a private clone with a 16-byte placeholder in the sandbox, the token off
the shared `.env`, a stopped broker refused by name before any sandbox exists,
and the vault deleted with the conversation. Then on production, on the
maintainer's account, on Sprites: the private clone with a 16-byte
placeholder, `HTTPS_PROXY` absent from `/home/sprite/.env`, and **direct egress
refused** by the `allow: [broker]` floor while the same hosts answered through
the proxy — the one line a runner cannot show, since it has no network policy
(a runner needs `BROKER_ALLOW_UNENFORCED` and is for development only). The
turn's own model calls and the ACP adapter's npm install passed through the
proxy as passthrough, which is gate 3's shape already visible in the broker's
request log. The placeholder is **not** a lookup key — the broker
replaces the auth header wholesale — so the "contract" below reduces to a
plausibility rule.

**Gate 1b — built 2026-08-25: bindings.** The binding model #1090 named as
the real cost. `Fountain.SecretBindings`: per tenant, per secret *name*, one
row per host with the auth shape (bearer, basic with a username, API-key
header with an optional prefix, custom headers with `{{ KEY }}`), validated
by the broker's own rules so what saves here is what it accepts. A secret
with an enabled binding is brokered; one with none is injected in the clear
as before — the presence of a binding is the `exposure` label §7 asked for,
without a second field. A console page (`/account/bindings`, shown only to
brokered tenants) and `/api/secret-bindings`, with the vendor's 35-entry
catalog as prefills. Gate 1a's hardcoded GitHub pair stays as the default for
`GITHUB_TOKEN` / `GH_TOKEN` that have no bindings of their own.

**Gate 1 — the placeholder contract.** Naming scheme, versioning, and a test that
fails when the two sides disagree. Then all environment and vault secrets that
are outbound HTTP credentials, with the ones that are not explicitly classified
and labelled per §7 — a third of what is stored, on today's numbers. Two items
0023 adds: the broker session token joins `Identity`'s `@process_only` so it
never reaches the shared `/home/sprite/.env`, and the session TTL is shorter
than a park so a checkpoint cannot carry a live token — noting Agent Vault's
TTL floor is 300 seconds and its default is 24 hours. Gate 0 adds three more:
the proxy URL shape above, the CA into the trust store rather than into six
variables, and a broker preflight at provision time so an unreachable broker
says so.

**Gate 2 — built 2026-08-25.** `allowed_hosts` translated into broker
passthrough services under `unmatched_host_policy=deny`; `unrestricted` is
`passthrough`; the sandbox's own policy is the `allow: [broker]` floor in both
cases, and the preflight no longer refuses a `limited` environment on a
brokered tenant. A host that carries a credential binding keeps its credential
service rather than gaining a passthrough twin. What §3 asked for, and what
gate 0 warned about: under `deny` the tenant lists what provisioning and the
runtime need (`registry.npmjs.org`, the model host), exactly as a Sprites
`limited` environment already required.

**Gate 3 — built 2026-08-25.** The runtime's inference credential is handed
to `default_env/2` as a vendor-shaped placeholder
(`sk-ant-oat01-__claude_code_oauth_token__`) and the value goes to the broker
with an implicit binding to the provider's host, where a **substitution**
replaces the placeholder wherever it appears — which is why one mechanism
covers Anthropic's `x-api-key`, the OAuth bearer, OpenAI's bearer and Gemini's
`?key=` query parameter alike, and why no base-URL survey was needed (this
absorbs 0016 gate 3). `Claude.fall_back_to_api_key/2`, the second injection
site, now re-prepares the vault so the substitution carries the API key
instead of injecting one in the clear. Substitution also became the default
shape for tenant bindings: a binding is "this secret may go to this host",
and the explicit header shapes are for an API the agent cannot address
itself; `basic` is the one shape substitution cannot reach, since the client
encodes the value. 0016 §4's second purpose (metering) remains a separate
decision.

Verified on production, 2026-08-25, one conversation per runtime on the
maintainer's account, each answering `PONG` with no real credential in the
sandbox: **Claude** (OAuth placeholder substituted on `api.anthropic.com`,
after #1155 taught the broker to carry every key's substitution on one
service per host — the first run had the API-key service win the host and
the OAuth placeholder go upstream unreplaced); **Codex** (`codex login
--with-api-key` accepts `sk-__openai_api_key__`, the turn's `api.openai.com`
call matched the service; its `chatgpt.com` login probe passes through and
401s, harmless); **OpenCode** (first run went to its own gateway, `opencode.ai`,
passthrough and credential-free, because Fountain pinned the model by its
bare id and opencode only knows `provider/model_id` — fixed in #1157; the
rerun called `api.anthropic.com` through the matched service and Anthropic
answered "credit balance is too low", which only an authenticated key gets,
so the substitution holds there as well). Gemini is covered by the same
substitution mechanism on `?key=` and remains unverified live. (Measured
2026-09-03 and settled the other way: gemini-cli sends the key in
`x-goog-api-key` and never in the query, so the header half is what carries
it. Query substitution exists again as of the parity close-out below, and is
not what makes Gemini work.)

**Gate 4 — built 2026-08-25.** The join is the vault name: §11's vault per
conversation is exactly what the empty `actor_*` fields on a session-scoped
row needed. `GET /api/conversations/:id/egress` returns the broker's request
log for the conversation, newest first — host, matched service (and so which
credential was attached), status, latency, and the broker's refusal code —
beside the intent half in `/events`. To keep the log, `Broker.release/1` no
longer deletes the vault at the end of a conversation: it revokes the
sessions and clears the credentials and services, and
`Fountain.Workers.BrokerVaultReaper` deletes the vault once the conversation
has been over for `BROKER_LOG_RETENTION_HOURS` (168 by default, at or below
the broker's own retention), along with any vault of ours whose conversation
no longer exists.

Gates 0–2 are the security argument and are worth building on their own. Gates 3
and 4 are where this ADR meets 0016, and neither is blocked on any ACP work.

## Alternatives considered

- **Do nothing; make `limited` the default and document it.** Cheapest by far and
  genuinely better than today. Rejected as sufficient because a host allowlist is
  the wrong granularity: it decides per host while a credential is per
  credential, so any host an agent may reach it may reach carrying every token it
  holds. It also leaves the tenant enumerating hosts, which is the burden that
  produced 0 of 20 adoption.
- **0016 §4 as written — base-URL override only.** Covers 3 of 78 secrets and
  requires a per-runtime survey that is still unblocked. Not rejected so much as
  superseded by a mechanism that gets the same result for all secrets with no
  runtime cooperation.
- **Build our own credential proxy.** We would own the TLS interception, the CA
  distribution into sandboxes, the rule engine, and the request log. That is a
  product, not a component, and 0016 §5's reasoning about not competing with
  better-funded companies applies with more force here than it did for sandboxes.
  Revisit only if §8's vendor decision has no acceptable answer.
- **Short-lived credentials instead of brokered ones** — mint a 5-minute GitHub
  token per conversation rather than proxying. Strictly better where the upstream
  supports it, because there is no proxy on the path at all. Rejected as the
  general answer because it is per-provider: it exists for GitHub and the big
  clouds and does not exist for the long tail of API keys tenants actually store.
  Worth doing *in addition*, for the providers that support it.
- **Enforce with per-process network namespaces inside the sandbox.** Finer
  grained and no external dependency. Rejected because it is per-provider
  substrate work we would have to build three times, and it still leaves the
  credential inside the blast radius — it restricts where a secret can go without
  changing the fact that the agent has it.
- **Wait for the ACP gateway and do this inside it.** Attractive as a single
  coherent story, and wrong on sequencing: egress is the control 0016's own reach
  table marks as the one ACP *cannot* see, so waiting for ACP to fix it is waiting
  for the wrong thing. 0016 already names the signal — if buyers ask about egress
  before approvals, the substrate is the product.

## Amendment (2026-08-25): rotating secrets, and the vault is per conversation

Two facts the gates established that the decision above does not state.
Both are built; neither changes a gate.

**A brokered secret may rotate while a conversation is open.** The design
assumed a secret's value is fixed for the life of the vault it was uploaded
to. Connections (#1178, ADR 0033) broke that: an OAuth access token lives an
hour, and a conversation can run for longer. The contract is therefore:

- The value the broker holds for a key is a *snapshot*. The sandbox never
  learns the value, so a rotation is invisible to it; the placeholder it
  carries is stable for the life of the conversation.
- `Fountain.Conversations.ConversationServer` re-reads every connection key
  it brokered (`connection_keys` in its state) at each **turn kick**, and
  when a value differs from the snapshot it re-prepares the vault with the
  new value before the turn runs. A refresh that fails leaves the old value
  in place: the turn runs on it and, if it has lapsed, fails at the provider
  with a reason rather than silently here.
- Rotation is per key, not per vault: the other secrets in the vault are
  untouched, and a binding a tenant added or removed between turns is
  picked up on the same re-prepare.
- A rotated secret is never re-sent to the sandbox. Nothing in the sandbox
  depends on the value, which is the whole point.

**The broker vault is per conversation, not per tenant.** §11 above says
per tenant. Gate 1a built `c-<conversation uuid without dashes>` instead,
for two reasons found while building it: a tenant running two conversations
with different `GITHUB_TOKEN`s (one from an environment, one from a vault)
would collide on one key with last-write-wins, and gate 4's request-log
attribution needs a vault whose name *is* the conversation, because
session-scoped tokens leave the log's actor fields empty. The vault is
released with the conversation (the log is kept for
`BROKER_LOG_RETENTION_HOURS`, then the reaper deletes it). Nothing in the
rest of this decision depends on the per-tenant shape.

## Amendment (2026-09-02): the broker is `managoat_broker`, run beside Agent Vault until the flip

§8 chose Agent Vault as the first implementation and said the abstraction
was worth building on the day there was a second broker. That day was
PR #1148 (2026-08-25), a native proxy inside the server, closed to wait for
the component-libraries plan ([0037](0037-component-libraries.md)). Decided
2026-09-02 on #1340, built in two PRs:

- **The broker is the `managoat_broker` library** (`Managoat.Broker`,
  `apps/managoat_broker`, PR A): #1148's proxy, CA, certificate cache,
  header injector and HTTP slice, ported onto `main` rather than rebased,
  behind one behaviour, `Managoat.Broker.Store` (`lookup(token)` in, a
  session of rules with the credentials resolved out). The library holds no
  reference to Fountain, reads no configuration, and takes the listen port,
  the store and the CA seed as start arguments. Its README lists what was
  deliberately not ported from Agent Vault (path/query/body substitution,
  WebSocket frame rewriting, auth rate limiting, body caps, IPv6 upstreams)
  and adds header-value substitution so gate 3's inference placeholders are
  replaced natively. **All but three of those gaps have since closed** — see
  the parity amendment below; this paragraph describes what shipped in
  September 2026, not the scope today.
- **Fountain runs it beside Agent Vault** (PR B). `Fountain.Broker` is a
  facade over two backends with every public function's name and arity
  unchanged: `Fountain.Broker.AgentVault` (the vendor client, selected by
  `BROKER_URL`) and `Fountain.Broker.Native` (the library, selected by
  `BROKER_LISTEN_PORT`; both set is a boot error). The native store is the
  `broker_sessions` table: token hashed, rules as one ciphertext under the
  tenant DEK, a TTL, and the conversation and user ids as the session's
  `meta`, which the proxy hands back on every `[:managoat, :broker,
  :request]` event so the log line names the conversation without the
  library knowing what one is. The CA root is derived from a seed that is
  itself HKDF-derived from the master key (`"managoat-broker-ca"`), so every
  replica presents the same root and nothing is stored. Merging is inert
  for the hosted deployment, which sets `BROKER_URL`.

## Amendment (2026-09-03): production flipped, and the vendor client is gone

Production moved to `BROKER_LISTEN_PORT` on 2026-09-03
(jhgaylor/home-cloud#153): the Traefik `IngressRouteTCP` for
`broker.inevitable.fyi` now points at the Fountain Service on 14322, the
Certificate moved into the `fountain` namespace with it, and the
`agent-vault` namespace and its CNPG cluster were deleted. `BROKER_URL`,
`BROKER_TOKEN` and `Fountain.Broker.AgentVault` are gone from the codebase
(#1487); boot refuses either variable rather than silently brokering nothing.
`Fountain.Workers.BrokerVaultReaper` is `Fountain.Workers.BrokerReaper`,
because there are no vaults to reap.

Two things the flip closed on its way past. Agent Vault rate-limited `CONNECT`
by TCP peer IP, and every sandbox reached it through a small pool of shared
NAT egress addresses, so one tenant's bad-credential burst returned 429 to
another's valid clone (#1206). And it answered 500 rather than 409 to a
duplicate vault name, which broke a brokered reattach after idle (#1185).
Neither failure has anywhere to live now: the native proxy has no
auth-failure limiter, by design, and no vaults.

Gate 4's stored request log **is** built on this backend (#1486): a
`broker_requests` row per proxied request, written from the proxy's telemetry
by a buffered writer, read by `GET /api/conversations/:id/egress`, swept by
the reaper on `BROKER_LOG_RETENTION_HOURS`. Response status and latency were
the one thing the Agent Vault log had that this one did not, because the byte
pump did not frame responses. That closed with the parity work below.

### What the flip cost, and what caught it

One regression, found by the first pre-flip smoke run and fixed the same day
(#1492). `Managoat.Broker` closes the connection after a `407`; Agent Vault
held it open and answered the retry on it. git leaves libcurl on `anyauth`,
which cannot send a credential before it has seen a challenge naming the
scheme, so every brokered clone failed with `Proxy CONNECT aborted` while
inference and `npm install` were unaffected, because those clients send the
credential preemptively. Fountain now pins git to `basic`. The proxy's own half landed in 0.1.2 (#1493): it now holds the connection
open for bounded authentication retries. Fountain still pins git to `basic`.

The lesson worth keeping: the parity checklist (#1359) compared the two
proxies feature by feature and found nothing here, because this is not a
feature. It is what a proxy does with a connection after it refuses one, and
only a real client on the real path exercised it.

## Amendment (2026-09-03): the Agent Vault parity gaps are closed, except three kept on purpose

The flip left a list of conscious deviations (#1359 was the pre-flip ledger,
managoat/managoat_broker#5 the library's plan, #1501 Fountain's half). The
library closed every row worth closing between 0.1.3 and 0.11.0;
`apps/fountain/mix.exs` moves from `~> 0.1.0` to `~> 0.11.0` and takes them.
The pin stays patch-level on purpose: pre-1.0 this library makes breaking
changes in a minor bump, so a minor reaches Fountain when someone edits that
line, never by resolution.

**What the broker can now do that it could not.**

- **A credential in a URL is brokered.** `:substitute` reaches the request
  target as well as header values, so the bot-API shape
  `/bot<token>/sendMessage` and a `?key=` parameter both work, over `CONNECT`
  and absolute-form alike. There is deliberately **no new `auth_type`** for
  it: a tenant declares that a key has a placeholder, and the proxy finds it
  wherever the client put it. `SecretBindings.Binding.@auth_types` is
  unchanged. The credential is written byte for byte, so one needing
  percent-encoding is declared already encoded, and one that cannot be
  written where its placeholder sits (a space or control character in a
  target, CRLF in a header value) is refused with 403 rather than mangled.
- **The egress log says how a request ended.** The request event is terminal,
  so `broker_requests.status`, `.latency_ms` and `.error` are written from it,
  which is the three columns the table was created with, nullable, for this.
  A consequence worth knowing: a row appears when the response **ends**, so a
  streamed reply is recorded when the stream finishes, and `latency_ms` is
  total duration rather than time to first byte. That is Agent Vault's
  semantics, not a compromise.
- **An IPv6-only origin resolves and connects**, with the SSRF guard extended
  to IPv6 first, including the four forms that embed an IPv4 address, which a
  range check alone calls public. Fountain's one job here is that a literal in
  a rule pattern must be bracketed, so `networking_config.allowed_hosts`
  brackets a bare one before it becomes a pattern. An unbracketed literal
  matches nothing rather than matching elsewhere, which under `limited` would
  have been an allowlist entry that silently allowed nothing.
- **Plain HTTP keeps the sandbox's connection alive**, so `apt` gets one
  connection instead of one per request. Two consequences here: the session
  store is resolved per request on that path rather than per connection (each
  absolute-form request carries its own `Proxy-Authorization`, and trusting
  the first would serve a token nobody checked), and
  `[:managoat, :broker, :connect]` counts **origin** connections rather than
  sandbox ones. Every ratio over that event keeps the numerator and
  denominator it had, so home-cloud's `FountainBrokerUpstreamFailures` is
  unaffected; only the absolute rate on that path moved.
- **A request body is capped** at 1 GiB and **reading one request** at five
  minutes, both Agent Vault's own defaults, and both left at the library's
  default rather than configured here. A response body is uncapped, which
  Agent Vault's default was too.

**One correction the parity work forced, which was Fountain's bug and not the
library's.** The event's `outcome` answers "did a rule apply", and a matched
`:passthrough` rule, the documented way a host is allowed under `limited`,
applies without attaching anything, so it arrives as `:injected` exactly as a
`:bearer` rule does. `broker_requests` derived its verdict from `outcome`
alone, so an allowed host's row named an `ALLOW` rule in `service` and read as
though a credential had gone to it. The 0.11.0 event carries `scheme`, which
is the field that separates them; the row and the
`fountain.broker.request.count` series now both mean "was a credential
attached". Found building managoat/airlock's egress record
(managoat/managoat_broker#27) rather than here, which is the argument for the
same event having more than one consumer.

**Three deviations stay, and they are decisions rather than a backlog.**

- **No WebSocket frame rewriting.** Substitution reaches the upgrade request
  like any other; frames after it are piped as bytes. Rewriting them means a
  frame-aware proxy handling masking, fragmentation, control-frame
  interleaving and negotiated compression before substitution is even
  correct, and nothing in the catalog or any binding sends a credential inside
  a frame.
- **No request-body substitution.** The same reasoning one layer down: the
  proxy streams request bodies rather than materialising them, which is what
  lets a large upload through at all, and no binding needs it.
- **The label half of the proxy credential is unchecked.** The random session
  token is the whole binding; the label exists because git refuses a proxy URL
  carrying a user and no password.

**Auth-failure rate limiting is no longer settled.** This ADR recorded that
the native proxy has no limiter "by design", and the reason was #1206: Agent
Vault's limiter was keyed by TCP peer address, every sandbox reached it
through a small pool of shared NAT egress addresses, and one tenant's
bad-credential burst returned 429 to another tenant's valid clone. The
condition attached to that decision was to revisit it if the assumption
changed, and then to key the limiter on something better than the peer
address. managoat/managoat_broker#22 argues it has changed: Agent Vault itself
had a second, scope-keyed limiter resolved after authentication, alongside the
IP-keyed one that caused the incident. That is an open library decision rather
than a Fountain one, and nothing here changes until it lands.

## Amendment (2026-09-12): the §9 ratchet is retired, and the two remaining non-broker paths are named

The per-tenant ratchet is gone. `Fountain.Broker.enabled_for?/1` and the
`:broker_tenants` configuration no longer exist, and `Broker.configured?/0` —
"is `BROKER_LISTEN_PORT` set" — is the whole gate. A deployment that runs a
broker brokers every tenant on it.

**Why now, and why it is a removal rather than a default.** The ratchet existed
to widen one id at a time while classification was proven, and it reached `*`
on 2026-09-04. From that day the per-tenant arm was unreachable in production
and untested anywhere except in the tests written for the ratchet itself. What
it left behind was sixteen call sites of the shape `if brokered?(user_id) do X
else identity end`, spread across `Egress`, `Connections`, `SecretBindings`,
`ConversationServer`, `SpriteEnv`, `PlatformInference` and five web modules.
Each of those `else` arms is a plaintext-credential path that nothing exercised
and nobody could reach. Deleting them is the point; the tidier `Egress` is a
side effect.

Two functions changed arity rather than keeping an argument the answer no
longer depends on: `Egress.brokered?/0` and `Connections.manageable_for?/0`.
`Egress.split_brokered/2`, `split_inference/3`, `release/1` and
`reattach_policy/3` lost the `user_id` they only forwarded, and
`Lifecycle.destroy/4` lost the one it forwarded to `release`. A call site that
still passed a tenant id would read as though the tenant were an input.

**`BROKER_TENANTS` survives with one job, and it is not rollout.** A list of
ids is now a boot error: booting on it would broker the tenants the list
deliberately excluded, which is a widening no operator asked for, so boot
refuses and names the removal. `*` stays accepted, because it carries the
assertion of **#1686**. That guard fails the boot in the dangerous direction: a
deployment that means to broker and loses its listener (the `envFrom` drift of
#1495) does not half-broker anyone. Brokerage turns itself off for everyone,
each sandbox gets plaintext GitHub, inference and connection credentials
instead, and the console and the connections keep working, so nothing
downstream can tell it from a deployment that meant to broker nobody. Removing
the ratchet removes the tenant list that used to carry that intent, and `*` is
the last place an operator can state it. It stays until brokerage is
unconditional, at which point the assertion and the variable go together.

**Two non-broker paths remain, and this amendment does not close either.**
Neither is described here as decided, because neither is:

- **The deployment off switch.** `BROKER_LISTEN_PORT` blank still means every
  credential enters the sandbox in the clear and the environment's own
  `networking_type` is what holds egress. **#2056** carries the decision, and
  names its blockers: #1671 (the CA install fails on about 18% of setups, and a
  mandatory broker has nothing to fall back to), #1638 (an explicit direct-egress
  opt-in, which pulls the other way), the 49 of 55 conversation test files that
  run the unbrokered path today, and the self-host boot requirements.
- **The unenforced arm.** A provider without `:network_policy` still cannot
  host a brokered conversation unless `BROKER_ALLOW_UNENFORCED` says so, which
  is why no conversation runs on a self-hosted runner ([0022](0022-self-hosted-runner-provider.md))
  on a brokered deployment. **#2057** carries that decision, together with the
  ADR 0022 and ADR 0036 amendments it implies.

Until those land, the honest statement of scope is the one in §9's first line,
with the tenant clause struck: brokering is a property of **the deployment** and
of the secret.
