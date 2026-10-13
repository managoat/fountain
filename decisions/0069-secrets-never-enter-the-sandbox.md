---
type: ADR
title: "A secret never enters the sandbox: it carries its hosts, and the broker is the only way it is delivered"
description: "Proposed, unbuilt: a value is either a plain env var, written into the sandbox, or a secret, which the sandbox sees only as a placeholder and the egress broker substitutes on the hosts the secret names. The host list moves onto the secret and the separate binding table, page and API go. Replaces ADR 0019 gate 1b, under which a secret with no binding entered the sandbox in the clear; makes the broker a requirement of every deployment."
tags: [security, secrets, sandbox, egress]
status: draft
adr: "0069"
adr_status: "Proposed"
date: 2026-10-13
---

# 0069 — A secret never enters the sandbox

**Status:** Proposed, 2026-10-13. Nothing described here is built. It amends
[0019](0019-egress-credential-brokerage.md): it replaces gate 1b (bindings)
and the "unbound secrets enter in the clear" rule of §1 and §9, and it settles
the off-switch question 0019's 2026-09-12 amendment left to #2056. The open
choices are listed under *Open questions* with a recommendation for each.

## Context

Jake's decision, 2026-10-13: **"No secrets belong in the sandboxes. Env vars
yes, secrets no."**

Today that is not how delivery works. 0019 brokers a secret only when the
user has created a binding for its name (`Fountain.SecretBindings`, moduledoc
in `apps/fountain/lib/fountain/secret_bindings.ex`): "A secret with none
reaches the sandbox in the clear, exactly as before the broker existed."
`Broker.split/2` (`lib/fountain/broker.ex`) takes a key out of the sandbox map
only if it has a binding or is one of the catalog pair `GITHUB_TOKEN` /
`GH_TOKEN`. Bindings are opt-in, and production has none: every one of its 63
environment and vault secrets enters the sandbox as a plaintext env var. This
is the failure 0019 §9 warned about (a well-designed control, opt-in, at zero
adoption), repeated one layer down. #2634 proposed deleting bindings outright;
it was closed in favour of this decision.

What already holds, and what does not:

| Value in the sandbox env | Today | Reference |
|---|---|---|
| Inference credentials (`CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` / `GOOGLE_GENERATIVE_AI_API_KEY`), tenant or platform | **Complies** when a broker is configured: vendor-shaped placeholder, substituted on the provider host. Claude's API-key fallback re-prepares the broker rather than injecting. | `Broker.split_inference/2`, `Egress.switch_to_api_key/1` |
| Codex `~/.codex/auth.json` | **Complies**: written with the placeholder above. | managoat_runtimes `Codex.prepare_sandbox` |
| `GITHUB_TOKEN` / `GH_TOKEN` | **Complies**: catalog pair, `api.github.com` bearer + substitution, `github.com` basic `x-access-token` (git encodes the value, so substitution cannot reach it). | `Native.catalog_rules/2` |
| Managed ChatGPT grant (`CODEX_CHATGPT_ACCESS_TOKEN`) | Complies (placeholder, protected route) — **and is being removed** with the ChatGPT subscription feature (branch `chore/remove-chatgpt-subscriptions`; ADRs 0047, 0052, 0060). Not carried forward here. | `CodexChatGPT.env/3` |
| Every other environment or vault secret | **Plaintext.** | `Broker.split/2` |
| `FOUNTAIN_TOKEN` (callback key) | **Plaintext**, process-only (kept off the shared `.env`), conversation-scoped, rotated on provision and reattach, revoked at terminate. | `CallbackKey.env/1`, `Identity` `@process_only` |
| Broker session token inside `HTTPS_PROXY` | **Plaintext by necessity**: it is the credential *to* the broker. Process-only, conversation-scoped, 6 h TTL. | `Broker.proxy_env/1` |
| Literal tokens in an agent's `mcp_servers` | **Plaintext**: free-form map, written as given; only `${VAR}` references go through the split. | `CotenantSecrets` moduledoc, `Fountain.Substitution` |
| Every credential, on a deployment with no broker | **Plaintext**: `Broker.configured?/0` false makes every `Egress` split an identity. | `Egress.split_brokered/2`, `split_inference/3` |

Two facts shape the design. First, **custody does not depend on the network
floor.** A placeholder is replaced only by the proxy, only on a host its rule
names, so a sandbox that can bypass the proxy (a runner under
`BROKER_ALLOW_UNENFORCED`, which production sets so runner conversations work;
`managoat_runner` advertises `[:suspend, :attach]`, no `:network_policy`) still
holds nothing worth stealing. The floor (0019 §2) enforces `limited` and keeps
the egress log complete; it is not what keeps secrets out. Second, **the SSH
clone path 0019 §7 worried about is gone** (`Provisioning.clone_one/5`,
deleted in #228): every repository is cloned over HTTPS with the GitHub
placeholder.

## Decision

**1. Two kinds of value.** An **env var** is configuration: written into the
sandbox as given, visible to the agent, and labelled as such everywhere it is
shown. A **secret** never enters the sandbox: the sandbox gets
`Broker.placeholder/1`'s stand-in and the broker substitutes the real value on
the secret's hosts. There is no third kind and no per-secret "deliver in the
clear" flag. If a value has to be readable inside the sandbox, it is an env var
by the user's explicit choice.

**2. A secret carries its hosts.** The binding folds into the secret row
(`secrets`, `vault_secrets`): a required, non-empty list of host patterns
(`host[:port][/path]`, validated as `Binding.changeset/2` validates them today)
and an injection shape. The `secret_bindings` table, `Fountain.SecretBindings`,
`/api/secret-bindings` (and `/presets`), `/account/bindings` and the 35-entry
preset catalog are removed. Because the hosts are on the row, the vault-wins
merge carries them: a vault secret overrides the environment's value *and*
hosts.

**3. Two injection shapes, not five.** The broker supports `substitute`,
`bearer`, `basic`, `api_key` and `custom` (`Native.binding_rules/4`). Keep:

- **`substitute`** (the default, no other field): the placeholder is replaced
  wherever the client puts it, header value or request target (0019 gate 3,
  `managoat_broker` 0.2.0). The agent sends the API's own shape.
- **`basic` with a username**: the one case substitution cannot reach, a
  client that base64-encodes the value before it leaves (git over HTTPS).

Drop `bearer`, `api_key` and `custom`, which add a header the agent did not
send. Nothing in production uses them (no bindings exist), and each is a
credential attached to requests the agent never asked to authenticate.

**4. Known names get their hosts without asking.** A secret named for an
inference credential takes its provider host (`Broker` `@inference`); one
named `GITHUB_TOKEN` or `GH_TOKEN` takes the GitHub pair. These are defaults
the user can see and override, as the catalog is today.

**5. The broker is required.** A deployment without `BROKER_LISTEN_PORT`
cannot deliver a secret or an inference credential, so it cannot run an agent.
Boot refuses rather than starting a server that can only fail at provision.
This answers #2056 yes, and retires `BROKER_TENANTS=*`, the assertion the
2026-09-12 amendment kept until brokerage was unconditional.

**6. Fountain holds itself to the same rule.** `FOUNTAIN_TOKEN` becomes a
placeholder substituted on `PublicUrl.base/0`'s host (the bundled skill and the
in-sandbox CLI send it as a bearer header, which substitution covers). The
broker session token in `HTTPS_PROXY` is the one named exception: it cannot be
brokered by the thing it authenticates to, and it is already process-only,
conversation-scoped and short-lived.

**7. Mixed-runtime co-tenancy is unchanged in shape.** A co-tenant's
credentials on the shared disk are placeholders under §1, so what one
conversation can read of another's is a stand-in, plus the process-only tokens
of §6 already named in `CotenantSecrets`.

## Open questions

Each is a choice for Jake; the first option is the recommendation.

**Q1. Existing secrets with no host (production: all 63, less the known names
of §4).**

- **(a) Withhold, loudly.** The secret is not delivered; provisioning publishes
  a `secret withheld: no host` stage event naming the key; console and API mark
  the row "needs a host". The user adds hosts, or deletes it and re-adds the
  value as an env var. Conversations still start.
- (b) Refuse to provision any environment or vault holding a hostless secret.
  Louder, but one stray secret stops every conversation on it.
- (c) A time-boxed "exposed" flag set on every existing secret by migration.
  Keeps today's behavior for a while, which is the opt-in failure again.
- (d) Reclassify hostless secrets as env vars automatically. Rejected: it
  moves credentials into an unencrypted column without anyone choosing it.

**Q2. Non-HTTP credentials (a database password for a direct connection, an
SSH key).** These cannot be brokered.

- **(a) Refuse as a secret; the user stores it as an env var**, which the UI
  and API label "visible to the agent". Honest, and matches the rule. Cost:
  `environments.env_vars` is not encrypted at rest (0019 §9), and vaults have
  no env vars at all.
- (b) Add a "sensitive env var": encrypted at rest and redacted from output,
  but delivered in the clear and labelled so. Same exposure as (a), better
  storage; a new column and UI.
- (c) An "exposed secret" escape hatch on the secret itself. Rejected: it is
  the third kind §1 rules out.

**Q3. `FOUNTAIN_TOKEN`.**

- **(a) Broker it (§6).** Closes the last Fountain-held plaintext credential
  short of the proxy token.
- (b) Name it an exception beside the proxy token: it is Fountain's own,
  conversation-scoped, rotated and revoked, so its blast radius is one
  conversation's API access.

**Q4. Runners without a network floor.**

- **(a) Allow them; the floor is a network-policy property, not custody.**
  `BROKER_ALLOW_UNENFORCED` is renamed for what it is (the provider cannot
  enforce `limited`), and a `limited` environment on such a provider is still
  refused. Settles #2057.
- (b) Keep the flag as a development-only escape hatch, as 0019 says today.
  Production already runs with it on.

## Consequences

**What shrinks.** `SecretBindings` and its schema, catalog, controller, JSON
view, LiveView and their tests. Every `Broker.configured?()` arm in `Egress`
(`split_brokered/2`, `bindings/1`, `split_inference/3`, `release/1`,
`apply_policy/4`'s unbrokered arm), plus `Provisioning.apply_network_policy/3`
and `check_network_policy_support/3`, which #2056 notes sit only on that arm.
`Broker.catalog_github_key/2` and the "unbound" logic. `LiveSecrets`' "an
unbrokered conversation ignores the cast" case: every secret change now takes
the #2548 path and reaches a running turn by rewriting broker rules.
`CotenantSecrets` loses its reason for inference values (they are placeholders
on disk) and can be reduced to the process tokens or removed.

**What stays, as a backstop.** `Redaction` and `RedactionCarry` keep
registering brokered values: a declared host that echoes a request header or
target back (0019's original finding in `SpriteEnv.build/4`) returns the real
value as tool output. Env vars stay registered for the reason #2366 gave. The
registry's front-line role ends; its latency cost does not, since the
brokered values are still in it.

**What becomes mandatory.** A broker listener on every deployment, including
self-host (`BROKER_LISTEN_PORT`, `BROKER_PROXY_URL`, an ingress the sandbox can
reach) and the test suite: #2056 counts 49 of 55 conversation test files on the
unbrokered path, so the suite boots a listener or keeps a test-only switch.
#1671 (CA install failures), #2056's first blocker, is closed. Every provider
Fountain ships (Sprites, E2B, Daytona) advertises `:network_policy`; the runner
does not, which is Q4. `docs/configuration.md`, `docs/open-source.md` and
`docs/concepts/secrets.md` stop describing the unbrokered case.

**API, SDK and CLI.** Environment and vault secret create (and the vault
`PATCH`) take `hosts` and an optional `basic_username`; list responses return
them (they are not secret). The vault copy carries them. `/api/secret-bindings`
is removed, which is a breaking API change for the SDK contract
(`sdk/contract/contract.json`, generated TypeScript). The CLI's `env` and
`vault` secret commands and the manifest's `spec.secrets` need a form that
names hosts.

**What a user must now do.** Know where each credential is used. A secret
referenced from an MCP server's headers must list that server's host; a secret
a setup script uses against a non-HTTP endpoint is an env var. The console has
to make "add hosts or make it an env var" a two-click fix, or Q1(a) is the
binding page's zero adoption again.

**Residuals, named.** The broker session token (§6). Literal credentials typed
into an agent's `mcp_servers` rather than referenced as `${VAR}`, which this
ADR does not detect. Env vars a user chooses to fill with a credential. A
declared host that reflects data back to the agent, bounded by keeping host
lists narrow and by redaction.

## Alternatives considered

- **Keep bindings and default new secrets to brokered.** Two places to declare
  one fact, and the binding page's adoption record says the second place is
  not visited.
- **Delete bindings and keep secrets in the clear (#2634).** Smaller, and the
  opposite of the decision.
- **Broker by guessing hosts from key names.** Works for the dozen names
  Fountain knows (§4) and for nothing else; a guessed host that is wrong sends a
  credential somewhere the user did not choose.
- **Keep all five injection shapes.** No user of them exists; each extra shape
  is one more way a credential is attached to a request the agent did not
  author.
