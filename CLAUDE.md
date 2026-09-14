# CLAUDE.md — Contributor Guide

This file is read by Claude Code (and other AI coding tools) at session start. Keep it accurate — stale guidance misleads every downstream dispatch.

## Product and goal

What Fountain is, in one paragraph, is the top of [README.md](README.md).
The standing goal since the May-2026 launch is **100 weekly active users by
month 6** (November 2026), and the one gate that hangs on it: org/team
features stay out of scope until that traction shows. Onboarding is the open
product decision on the way there (#1039). These two lines used to live in
`OPERATING_MODEL.md` and `ROADMAP.md`, the bus files for the captain-picard
orchestrator that built the first cut; that fleet stopped running against this
repo after launch and both files were deleted, so this is now the only place
the goal is written down.

## Working with Review Loop

When working on a Review Loop PR, read the
[repository skill](.agents/skills/review-loop/SKILL.md) for bot commits, CI repairs,
human decisions and bounded retries. Report outcomes briefly. The approved-base
`.github/review-loop.yml` and its referenced files remain the policy authority.

The skill is copied unchanged from
[Review Loop Action `9278790`](https://github.com/managoat/review-loop-action/blob/92787907f1b236d471555e3d231443582e46ce12/skills/review-loop/SKILL.md).
Review upstream changes before replacing it; its MIT license is included.

## Quick start

```bash
mise install                        # pin Erlang/OTP 28 + Elixir 1.19.2
mix deps.get
mix setup                           # dev DB: create + migrate
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test                            # full suite (~1,850 tests)
mix precommit                       # the core CI checks, locally
```

See [SETUP.md](SETUP.md) for full workstation bootstrap (Postgres, OAuth keys, etc.).

## Repo layout

```
fountain/                  umbrella root
  apps/
    fountain/              core business logic (Elixir OTP app)
      lib/fountain/        contexts: Accounts, Agents, Environments, Vaults,
      |                              Conversations, Crypto, Audit
      lib/fountain_web/    Phoenix: controllers, LiveView, plugs, router
      test/fountain/       context unit tests (async: true, DataCase)
      test/fountain_web/   controller/LiveView integration tests
      test/support/        DataCase, ConnCase, factory.ex
    fountain_buzz/         the two first-party extensions (ADR 0043, tracker
    fountain_support/      #1503 and #1528). Each is an AGPL OTP app that
                           depends on :fountain, is named in
                           `config :fountain, :extensions` and is reached only
                           through the `Fountain.Extension` callbacks. Buzz owns
                           FountainBuzz.*, buzz_identities and its migrations,
                           /api/buzz + /api/mcp/buzz, and the harness tree;
                           Support owns FountainSupport.*, support_reports,
                           /api/support and the report forwarder.
                           `apps/fountain` depends on neither in any direction
                           and names no module of either
                           (extension_guard_test.exs); the release's
                           `applications:` decides inclusion. Their suites run
                           from their own directories, so
                           `scripts/test-libraries.sh` runs them in CI. A new
                           extension needs a row in extension_guard_test.exs
                           and a boundary test of its own; adding a tenth
                           `Fountain.Extension` callback needs an ADR.
                           Buzz also owns its supply chain (#1509):
                           buzz-acp.version, buzz-acp.source and the
                           buzz-acp-publish workflow's inputs live in its app,
                           and FountainBuzz.Assets both finds the binaries and
                           refuses one whose version does not match the pin.
                           `BUNDLE_EXTENSIONS=false` builds the core distribution —
                           no Buzz application in the release (mix.exs) and no
                           binaries in the image (Dockerfile), one switch for
                           both.
                           Buzz also owns a Go module, apps/fountain_buzz/cli
                           (#1508): the buzz-backend-fountain remote-agents
                           provider Buzz Desktop discovers by name on PATH,
                           Apache-2.0 like cli/ and released for the same four
                           platforms as the fountain binary. A module of its
                           own so Go's internal/ rule stops it reaching
                           cli/internal/...; it uses the public cli/api +
                           cli/credentials instead. `fountain buzz agents ...`
                           deliberately STAYS in cli/ (ADR 0043 decision 6) —
                           removing a subcommand from a released binary is a
                           user-visible break with nothing bought. Run its
                           tests from its own directory; `go test ./...` in
                           cli/ does not reach a second module.
    (managoat_*/)          the component libraries extracted from the server
                           (ADR 0037, tracker #1334): Apache-2.0, Managoat.*
                           namespace, no reference back into Fountain. Each
                           began as an in_umbrella app here and all nine have
                           graduated (#1345, then #1368): on hex, pinned
                           "~> 0.1.0" in apps/fountain/mix.exs, source in the
                           repository managoat/managoat_<name>, no directory
                           here. A future one starts as an app again;
                           CONTRIBUTING.md has both recipes.
        managoat_substitution  Managoat.Substitution, the ${VAR} engine
        managoat_mcp_auth      Managoat.McpAuth, RFC 9728/8414/7591 MCP
                               authorization discovery with the SSRF guard
        managoat_oauth         Managoat.OAuth, the OAuth 2.0 code+PKCE and
                               device-grant state machine as a `use` macro
                               over Managoat.OAuth.Host; Fountain.OAuth is the
                               instance, Fountain.OAuth.Host mints the API key
        managoat_acp           Managoat.ACP, the client-side ACP session
                               (Peer), Protocol, Permissions, Blocks, Usage,
                               Tracer and the ScriptedAgent behind a writer
                               callback; the provisioning half is
                               managoat_runtimes (below);
                               Conversations.Blocks stays here
        managoat_sandbox       Managoat.Sandbox, the sandbox behaviour, the
                               Sprites/E2B/Daytona adapters, Retry, the Fake
                               and the conformance case; the "which providers
                               are enabled here" policy
                               (Fountain.SandboxProviders) stays here.
                               apps/managoat_runner takes it from hex too.
        managoat_docs          Managoat.Docs, the compile-time embedded manual
                               (a `use` macro Fountain.Docs is one instance
                               of), Managoat.Docs.Markdown (both render paths)
                               and Managoat.Docs.GuardrailCase; docs/, nav.yml,
                               Fountain.Help, the prose gates and the /docs
                               controller stay here
        managoat_broker        Managoat.Broker, the native egress credential
                               proxy (CONNECT + absolute-form forward proxy,
                               the derived CA, the header injector) behind
                               Managoat.Broker.Store; fountain implements the
                               store over broker_sessions, runs the listener
                               in-process (BROKER_LISTEN_PORT) and writes the
                               egress log to broker_requests. It is the only
                               backend since the 2026-09-03 flip (ADR 0019)
        managoat_runner        Managoat.Runner, the self-hosted runner wire
                               protocol (Connection), the sandbox adapter over
                               it, the sandbox-name shape and the FakeDaemon,
                               behind Managoat.Runner.Host; Fountain.Runners.Host
                               implements it over Horde, and the runners
                               table, placement and presence stay here
        managoat_runtimes      Managoat.Runtimes, how claude/codex/gemini/
                               opencode get into a sandbox speaking ACP: the
                               behaviour and for_runtime/1 (the agent is a
                               plain map, not %Agent{}), the pinned ACP
                               adapter table and install, Layout,
                               Instructions, Quirks, the provider/model_id
                               parser (Model), Skills and the FakeRuntime.
                               The model suggestion catalog
                               (Fountain.Agents.ModelCatalog), the bundled
                               skill content (Fountain.SandboxSkills), the
                               permission-ask timeout read
                               (Conversations.Lifecycle.ask_timeout_ms/0),
                               and InferenceCredentials stay here
  ee/                      credits, Stripe and the credit emails (welcome,
    lib/fountain/          credits-low/exhausted), compiled into the
    lib/fountain_web/      same :fountain app via elixirc_paths. Licence: ee/ is
    test/                  Elastic 2.0, the server is AGPL-3.0 (0010, 0027).
                           Account email + Mailer are core (#475/#476).
  config/
    config.exs             shared config
    dev.exs                dev overrides
    test.exs               test overrides (pool_size: 20, test-mode flags)
    prod.exs               prod overrides
  .github/workflows/ci.yml CI pipeline
  decisions/               ADRs (Architecture Decision Records)
  docs/                    the public manual, served at /docs (nav.yml is the nav)
```

## Architecture: the four primitives

| Primitive | Purpose |
|---|---|
| **Environment** | Baseline set of encrypted env vars + runtime config (packages, repos, scripts) attached to an agent. A conversation may name a different one at launch (`environment_id`; scoped by `agent.allowed_environment_ids`) — the agent's is the default, not the only choice |
| **Vault** | Free-floating bag of env-var overrides. Vault values **win on key collision** when merged with an environment at sprite spawn time |
| **Agent** | A named, re-runnable agent config — model, runtime, skills, MCP servers, optional environment |
| **Conversation** | A single run of an agent inside a Sprites sandbox. Has turns, log events, and a status lifecycle |

## Credits are the product (ADR 0031)

There are no plans, no tiers and no subscription. `CREDITS_ENABLED` means
"credits on"; off, nothing is priced, granted, gated or shown. Five rules
that are easy to get wrong:

- **The gate is the balance.** `Billing.check_spend/1` is `Credits.gate/1`:
  `:ok` with billing off, for a comped account (`users.comped`, the one
  operator lever), or a positive `credit_balance_cents`; else
  `{:error, :insufficient_credits}` (402 with `upgrade_url`). Every door that
  spends calls `check_spend/1`; the reservation lock in
  `Quotas.with_sandbox_reservation/3` checks it too. In-flight turns finish
  and may go negative (ADR 0030 decision 6). There is no `check_active/1`.
- **The opening credit lands at verification.** `Accounts.verify_email/2`
  posts `Credits.grant_opening/2` — `CREDIT_OPENING_CENTS` ($5) expiring
  `CREDIT_OPENING_DAYS` (14) later, idempotent per account. In tests
  `insert_verified_user/1` therefore holds $5 and may spend; drain it with a
  `burn_turn` debit to test refusal. `insert_active_user/1` is the same
  function, kept for readability.
- **Concurrency is funded by the balance, under a fleet ceiling.**
  `Quotas.sandbox_limit/1` = `sandbox_limit_override` if set, else
  `clamp(balance ÷ SANDBOX_RESERVE_CENTS, SANDBOX_CAP_FLOOR, SANDBOX_CAP_CEILING)`
  (defaults $2 / 2 / 20; comped and billing-off get the ceiling).
  `SANDBOX_FLEET_CEILING` bounds live sandboxes across every tenant under a
  global advisory lock taken before the per-user one; `:fleet_full` is 503,
  not 402. Anything that displays a cap shows `Quotas.sandbox_limit_for/1`.
- **A turn hour is not a sandbox hour.** Turns burn credit against
  `SandboxUsage`'s `turn_seconds` (summed per turn, clipped to the period) on
  platform-paid providers only — an idle sandbox and a self-hosted runner
  spend none of it. `busy_seconds` is the *union* of the same intervals and is
  what a provider bill relates to; several conversations share one sandbox
  (ADR 0023), so the two differ and must not be swapped.
- **The ledger.** `Fountain.Credits` keeps a cents ledger (`credit_ledger`,
  cached on `users.credit_balance_cents`, idempotent per row, never summed on
  a gate; every credit row is a lot with `remaining_cents`, and a debit
  consumes lots in order: the lot it names, earliest expiry, then purchased).
  `CreditPricer` burns closed turns at `CREDIT_TURN_HOUR_CENTS` (default 25),
  seven days back;
  `CreditExpirer` (and the pricer's tick) expires unspent grants; `Credits.Purchases` sells packs
  through one-time Checkout and claws back on `charge.refunded` /
  `charge.dispute.created`. Stripe holds no subscription and no price.
  Usage is reported over the calendar month (`Billing.current_month_range/0`).
  **decisions/0031-credits-are-the-product.md** and
  **decisions/0030-prepaid-credits.md** own the rest.

## Tenant isolation contract

Every user-facing query is scoped by `user_id`. The pattern is consistent:

```elixir
# CORRECT — tenant-scoped
Agents.get_agent(id, user_id)
Agents.list_agents(user_id, filters)

# WRONG — unsafe, admin-only, prefixed accordingly
Agents._unsafe_get_agent(id)
Conversations._unsafe_get_sandbox(id)
```

Functions prefixed `_unsafe_` bypass tenant scoping. **Never call one as the
first fetch in a user-facing request** — ownership must already be
established on that request before an `_unsafe_` call is legitimate.

The prefix goes on *every* unscoped function, including ones whose callers
happen to check ownership first — the reader of a call site should not have to
go and find out. The legitimate callers are:

- an admin surface behind `require_admin`;
- a system-level sweep like the rehydrator or `SandboxReaper`;
- a GenServer that has already established ownership;
- **a user-facing call site directly after a tenant-scoped parent fetch** —
  the dominant pattern since #383:

  ```elixir
  # CORRECT — ownership established by the scoped get_vault above
  vault = Vaults.get_vault(vault_id, user.id)
  secrets = Vaults._unsafe_list_secrets(vault)
  ```

  The scoped fetch and the `_unsafe_` child call must be adjacent and in the
  same function, with a comment saying which fetch established ownership.

## Envelope encryption

Secrets (environment and vault) are encrypted at rest using a per-tenant DEK (Data Encryption Key) derived from a platform master key:

```elixir
{:ok, dek} = Fountain.Crypto.load_tenant_key(user_id)

# Persist
Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => "plaintext"}, dek)

# Read back
%{"TOKEN" => "plaintext"} = Environments.decrypted_env(env, dek)
```

- `dek` is a binary; `upsert_secret` accepts **string-keyed** maps (`%{"key" => ...}`).
- `decrypted_env/2` returns a plain `%{"KEY" => "value"}` map (not a tagged tuple).
- The master key lives in `MASTER_SECRETS_KEY` env var. See `.env.example`.

## Substitution engine

`Managoat.Substitution.apply(value, vars)` substitutes `${VAR}` references.
It is the hex package `managoat_substitution`, the first library extracted
under ADR 0037 and the first to graduate to its own repository
(managoat/managoat_substitution, #1345); `apps/fountain/mix.exs` pins it at
`~> 0.1.0`. There is no `Fountain.Substitution` any more.

- `${VAR}` → value from `vars` map
- `$$` → literal `$`
- Returns `{:ok, result}` or `{:error, {:missing_vars, sorted_list}}`
- Recursively walks maps and lists; collects **all** missing vars, not just the first

## The web UI is a console

Fountain's own browser UI is an **operator console**: the dashboard, agents,
environments, vaults, audit, API keys, account and admin. It is deliberately
not an interactive application.

Watching an agent work and messaging a teammate are separate single-page apps
on `/api`, on their own origins with their own OAuth clients:

| App | Repo | Replaced |
|---|---|---|
| Conversations | [managoat/demos `apps/fountain-conversations`](https://github.com/managoat/demos/tree/main/apps/fountain-conversations) | `/conversations`, `/conversations/new`, `/conversations/:id`, `/conversations/:id/logs` |
| Team | [managoat/demos `apps/fountain-team`](https://github.com/managoat/demos/tree/main/apps/fountain-team) | `/team`, `/team/:agent_id` |

`Fountain.Apps` is the only place that knows where they live
(`CONVERSATIONS_APP_URL` / `TEAM_APP_URL`, defaulting to the hosted builds;
`""` means this deployment has none). Anything that links a human to a
transcript — the console, an email, a forwarded support report, `/api/catalog`
— reads it from there. Retired browser `/conversations*`, `/team*` and
`/onboarding*` URLs return the normal 404 response (#2105). Current links use
the configured apps or `/dashboard`; the separate `/api/account/onboarding`
API remains available. The retirement boundary and bookmark migration are in
`docs/concepts/surfaces.md`.

**Building a conversation-facing feature? It goes in the app, not here.** The
server's job is to serve it: `?blocks=true` on `/events` and the streams means
no client re-parses a runtime dialect.

The marketing pages are not here either. `managoat.com/`, `/launch`,
`/integrations`, `/built-with`, `/self-hosted`, `/faq` and the case study are
[managoat/site](https://github.com/managoat/site), a static site the ingress
puts in front of the app on the hosted host (ADR 0034, amended 2026-09-14).
The app serves a plain front door at `/`, the operator's legal pages and
`/docs`; `MARKETING_SITE=true` only makes the manual's chrome link the site's
pages. **Marketing copy goes in that repo, not in a template here.**

## LiveView auth hooks

`FountainWeb.Live.Hooks` provides these `on_mount` guards:

| Hook | Unauthenticated | Authenticated but ineligible |
|---|---|---|
| `require_authenticated_user` | `redirect` to `/auth/login` | unverified: `redirect` to `/auth/verify-pending` |
| `require_pending_verification` | `redirect` to `/auth/login` | already verified: `redirect` to the dashboard |
| `require_admin` | `redirect` to `/auth/login` | `push_navigate` to `/dashboard` |

The distinction matters in tests: plain `redirect` yields `{:redirect, _}` (the
login redirect), while `push_navigate` yields `{:live_redirect, _}` (the
non-admin case in `require_admin`).

There is no router-level billing gate. The gate that protects spend is
`Billing.check_spend/1` **in the context** (ADR 0031), so every door gets it
— see `ee/test/fountain/credits_enforcement_test.exs`.

## Rate limiter

`FountainWeb.Plugs.RateLimit` — ETS-backed, per node. The `:api` pipeline
runs it twice: keyed by IP before auth (600/min) and keyed by API key after
it (`key: :api_key`, 600/min), because every app deployed beside the server
arrives through one ingress address. In tests:

```elixir
# config/test.exs
config :fountain, :rate_limit_test_isolation, true
```

This switches the key to `{bucket, self()}` so async ExUnit tests don't share counters. Leave this enabled in test config.

## Ueberauth test mode

The `UeberAuthController` skips `plug Ueberauth` when `ueberauth_test_mode: true` (set in `config/test.exs`). This prevents the OAuth plug from overwriting manually-set `conn.assigns` in tests. Don't remove this flag.

## Audit logging

**Mutations audit in the context, not the caller.** A function that changes
tenant-owned state records its own event, so the UI, the API, background
workers and any future surface are covered by construction rather than by each
caller remembering. This is the rule the #540 campaign established after
finding seven contexts with no audit calls at all and coverage that depended on
which door a request came through.

```elixir
# CORRECT — the context records; the caller supplies only attribution
def create_agent(attrs, opts \\ []) do
  %Agent{} |> Agent.changeset(attrs) |> Repo.insert() |> audited("agent.created", opts)
end

# at the call site
Agents.create_agent(attrs, Audited.attribution(conn))     # or (socket)
Agents.create_agent(attrs, actor: "system:my_worker")     # background caller
```

`FountainWeb.Audited.attribution/2` returns the `:actor` / `:request_ip` pair
for a `%Plug.Conn{}` or a LiveView socket. Pass an override where the
connection cannot reveal the actor — at registration and at
`POST /api/auth/token` there is no session yet, so derivation would report
`"system"` for a plainly-human action.

Three rules that are easy to get wrong:

- **Never audit inside a transaction.** `record/1` is best-effort *by rescuing*,
  and that does not survive a transaction — a failed insert aborts the enclosing
  one, so a lost audit row would take the mutation with it. Record outside.
- **Never record values.** Update events name the fields that changed
  (`Audit.changed_fields/1`); secret, credential and prompt events record keys,
  sizes and providers. The trail is not a second copy of tenant data.
- **Only record what happened.** A rejected changeset or a no-op sync records
  nothing; a trail that logs attempts as changes is worse than no trail.

`apps/fountain/test/fountain/audit_guardrail_test.exs` enforces this: add a
context mutation and the guardrail fails until it audits, or until you add it
to the documented exclusion list with a reason.

The actor vocabulary is closed: `self` (the context default), `ui`, `api`,
`sprite`, `admin`, `admin:<operator_id>` (account deletion only) and
`system:<worker>`. A bare `"system"` — what `attribution/2` derives when a
request has no principal — is a defect, not a value: the unauthenticated
routes (login, registration, `POST /api/auth/token`, email verification) pass
an explicit actor. **decisions/0013-audit-trail.md** owns all of this, plus
the deliberate exclusions, the two-rows-per-API-mutation choice and the
deletion semantics; read it before adding an actor string or moving a
recording out of a context.

`Fountain.Audit.record!/1` is deliberately test-only — see its docstring. Never
wrap `record/1` in a way that makes it blocking for the user.

## CI pipeline

`.github/workflows/ci.yml` runs on every push to `main`, all PRs, and every
merge group (see *How a change lands* below). The
gates are grouped into jobs that share nothing, so the job name in a red
build tells you which toolchain to go and look at:

| Job | What it runs |
|---|---|
| **workflow-checks** | `CI policy and alert tests`: conflict-marker detection (`scripts/conflict-markers.py`), the Python suite in `scripts/ci/` that gates CI's own decision logic, and Prometheus alert-fixture evaluation (`scripts/test-alerts.py`). Required even for docs-only changes and reused trees |
| **test** (×6) | The suite, as six partitions (`scripts/test-partition.sh`), plus a `coverage` job that merges their exports with `scripts/coverage-gate.exs` and enforces the 85% threshold |
| **elixir-static** | `mix deps.unlock --unused`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `scripts/hex-audit-gate.exs`, `scripts/sobelow.sh`, `MIX_ENV=dev mix dialyzer` |
| **release-and-contract** | `mix ecto.create && mix ecto.migrate`, the prod release boot check (probes `/health` and `/health/ready`, runs a release task beside the live server), `mix openapi.spec.json` + `jq empty`, and `scripts/sdk-contract/build.sh --check` |
| **changes** | Classifies the diff and emits the plan every other job reads: `docs_only` (which gates the server jobs), `docs_touched`, `cli_docs`, `tree`, and one `sdk_*` per language (`scripts/ci/sdk_changes.py`). Fail-open: an unreadable diff, an unregistered path or a shared file selects every SDK. Runs on `pull_request`, `merge_group` and `workflow_dispatch` — never on `push`, where the outputs are empty, so every `!=`-gated job runs and only `docs` (which tests `docs_only == 'true'`) stays skipped |
| **already-tested** | `Skip the re-run when a PR already tested this exact tree`: `scripts/ci/already-tested.sh` compares the checkout tree with a successful run's `tested-tree` artifact. Runs only on `push` and `merge_group`; a skip on `pull_request` or `workflow_dispatch` is normal and supplies no reuse proof. Missing or expired artifacts and API failures leave `skip=false` |
| **elixir-sdk** (×2) | The Elixir SDK on its declared minimum (1.15.8 / OTP 26.2.5.21) and the pinned current pair, plus conformance fixtures |
| **python-sdk** (×2) | The Python SDK on its declared boundaries (3.9 and 3.13), conformance fixtures, and a built wheel installed into a fresh venv outside the source tree |
| **typescript-sdk** (×2) | The TypeScript SDK on the minimum Node in `engines.node` (20.19.0) and on 24, conformance fixtures, and the packed tarball installed into a throwaway consumer project |
| **swift-sdk** (×2) | The Swift SDK on ubuntu-24.04 and macos-15, with its own conformance step. It runs no `sdk/conformance/lint.py` |
| **cli-plugins** | Both Go modules (`cli/` and `apps/fountain_buzz/cli`) with vet and gofmt, the Hermes plugin, and the deployed-instance runner tests under `deployed/test/` |
| **core-distribution** | `Core distribution boots without the extensions`: builds with `BUNDLE_EXTENSIONS=false`, boots and migrates a fresh database, probes health, and checks that extension applications and API paths are absent. Rebuilds with extensions enabled to check their inclusion too. Skips docs-only changes and reused trees |
| **compose-fresh-clone** | `Compose fresh-clone check`: runs `docker compose config --quiet` without `.env`, `SECRET_KEY_BASE` or `MASTER_SECRETS_KEY`, so the documented database-only startup can load the Compose file. Skips docs-only changes and reused trees |
| **compose-pinned-image-boot** | `Compose boots the pinned image`: `scripts/compose-boot-check.sh` exercises the current Compose quick start against its pinned release image. Skips docs-only changes and reused trees. An unpublished image pin that matches the version in `mix.exs` defers the boot check to `release.yml`; any other missing pin fails |
| **sdk-checks** | A stable aggregate over the four SDK jobs. A selected SDK is expected to *succeed* even when the server plan is docs-only, because an SDK's own docs page selects it (`gate.py`'s `_expected_plan`). Legs skip only for a reused tree or a language the classifier did not select, and green then means *correctly skipped*, not *SDKs tested* |
| **docs** | `Docs`: compiles the embedded manual, runs `docs_test.exs` and `docs_controller_test.exs`, checks public GitHub documentation links, and retains advisory prose reports. Runs CLI documentation parity tests when `cli_docs` is true. Selected only when `docs_only` is true, including reused docs-only merge groups; skipped on `push`, whose classifier does not run |
| **docs-prose** | Advisory wording reports when docs, prose configuration or the workflow changes, and on a full main run. Docs-only PRs get them from `docs`; structural checks still block |
| **gate** | `CI required`: validates all expected job results and records a successful PR checkout tree |

Measure the slowest partition plus coverage and runner queue delays before
adding runners. Dialyzer can dominate cold runs; the core release has its own
compiled-build cache. `scripts/ci/README.md` describes timing refresh and
required-check activation.

`mix hex.audit` is not one of these: `scripts/hex-audit-gate.exs` **fails the
build** on a security advisory unless it is acknowledged in `mix.exs`, and
only retirements stay non-blocking (an upstream maintainer can retire a
package at any moment, and that should not break unrelated work).

`config/hex_advisories.exs` additionally acknowledges the incorrect Decimal
CVE-2026-32686 finding only for the reviewed 3.1.1 Hex artifact, matching both
checksums. Remove that acknowledgment when the EEF feed is corrected; changing
the locked artifact drops it automatically. The exponent rejection and artifact
matching regressions live in `hex_advisories_test.exs`.
Evidence is in `decisions/evidence/decimal-advisory.json`; reproduce the public
registry controls with `python3 scripts/verify-decimal-audit.py`.

On `main`, `already-tested` can reuse a successful PR **or merge-group** run's
`tested-tree` artifact. That artifact records the actual checkout tree, and is
uploaded only after `CI required` passes. A missing, expired or different
artifact runs full CI. Main and merge groups run independently; superseded
PR runs cancel. Wording reports are advisory; security and structural docs
checks remain blocking.

### How a change lands

Main takes roughly 26 merges a day, and a PR that was green an hour ago was
green against a different main. A **merge queue** closes that gap: you no
longer merge a PR, you *queue* it, and GitHub builds the exact tree the merge
would produce before letting it in.

```bash
gh pr merge <N> --squash --auto     # queue it; the queue merges when green
```

**A PR still needs an approving review to get in.** GitHub refuses to enqueue a
PR whose merge requirements are unmet, so an unreviewed PR does not fail —
it never enters, and `--auto` sits there looking like the queue is broken. If a
PR seems stuck, check `gh pr view <N> --json reviewDecision` before you check
anything else. Approval is a human's to give; never manufacture one from a
second account to get a PR moving.

What else changes, in practice:

- **Nothing needs rebasing to be mergeable.** The up-to-date requirement is
  off, because the queue tests the merge result directly rather than asking a
  branch to prove it was recently rebased. Rebase because you want the code,
  not to satisfy a gate.
- **A queued PR can still be rejected.** If the group fails, the PR is ejected
  and stays open with the failure attached. That failure is usually real —
  it is your change against a main it had never been tested with.
- **Merging is no longer instant**, and should not be waited on synchronously.
  A lone PR waits up to five minutes for company (batching is how the queue
  affords a full suite under the free plan's 20 concurrent jobs), then builds.
- **Main's push stays cheap.** The queue's run publishes the `tested-tree`
  artifact and main's push finds it, so a queued merge costs one full CI run,
  not two.

**Stacked PRs do not go in the queue** until they are the tip. GitHub only
queues a PR whose base is `main`, so a stack still lands one stage at a time:
merge stage 1, let GitHub retarget stage 2 to `main`, queue stage 2. The
retarget is now GitHub's job rather than yours, which removes the trap where a
stale base merged cleanly into a branch that no longer existed. Land a feature
as a stack of small chained PRs exactly as before.

`scripts/ci/README.md` documents the four CI events and the queue's sizing;
`gate.py`'s `PROBES` table is the authority on what each event owes.

### Coverage

Coverage uses Elixir's built-in cover, not ExCoveralls — ExCoveralls cannot
merge results across machines, and since #620 the suite runs as six
partitions on six of them (three until #894). Settings live in `coverage.exs` at the repo root
(read by both mix.exs files): `summary: [threshold: 85]` and `:ignore_modules`,
which replaced `coveralls.json`'s `minimum_coverage` and `skip_files`.

`:ignore_modules` matches **module names**, not source paths — a bare atom for
one module, a regex against `inspect(module)` for what used to be a
directory entry. Locally, `mix test --cover` reports and gates in one step.

CI enforces the threshold with `scripts/coverage-gate.exs`, not
`mix test.coverage`: ~90% of that task's time is rendering an HTML report the
job never opens. The script reads the same `coverage.exs` and was verified to
produce the identical total (85.46% on the same six exports). Run
`mix test.coverage` locally when you want the per-module table or the HTML —
and re-verify the two agree when bumping Elixir, since the script depends on
`:cover` semantics the pin currently freezes.

Run `mix precommit` locally before pushing — it covers the core gate (compile
with warnings-as-errors, unused deps, format, `credo --strict`, sobelow,
dialyzer, a prod release **assemble**, tests). CI additionally runs hex.audit,
the Go CLI checks, the release **boot** check, and OpenAPI validation.

The release assemble is the only step that builds `MIX_ENV=prod`, and it is
there because everything else is blind to a prod-only dependency graph: the
OpenTelemetry family is `only: :prod`, so `chatterbox` exists in no dev or test
build, and the hackney 4 bump that collided with it left every other gate green
on a tree whose release would not assemble (#1472, #1477). It costs ~9s warm;
the first run in a fresh checkout pays a full prod compile (~2 min) and then
caches it under `_build/prod`. It needs no secrets — assembling copies
`config/runtime.exs` in as a config provider rather than evaluating it, which
is why CI keeps the booting half where `SECRET_KEY_BASE` and a database are
required.

## Test patterns

`mix test` at the umbrella root runs core, `ee/test` **and** every sibling app
(`apps/fountain_buzz`, `apps/fountain_support`). To run a single ee file by
path, run from `apps/fountain` (`mix test ../../ee/test/...`) or pass an
absolute path — root-relative `ee/...` paths don't resolve.

`apps/fountain` deliberately depends on no sibling app, so neither
`:fountain_buzz` nor `:fountain_support` is on the code path there: running from
`apps/fountain` (which is what CI's partition script does) runs core only, and
`config/runtime.exs` installs each extension **only where it loads**. Run an
extension's suite from its own directory, or from the root.

### Database tests

```elixir
use Fountain.DataCase, async: true   # SQL Sandbox, isolated per-test
```

Pool size is `20` to handle concurrent async modules. Don't lower it.

### Factory helpers

All helpers live in `test/support/factory.ex` and are imported by `DataCase`:

```elixir
user = insert_verified_user()
agent = insert_agent(user_id: user.id)
env   = insert_env(user_id: user.id)
vault = insert_vault(user_id: user.id)

# Factories accept keyword lists or atom/string-keyed maps
# and always persist through the real changeset pipeline
```

`*_attrs/1` helpers return **string-keyed** maps (e.g. `%{"name" => "..."}`) — match with `attrs["name"]`, not `attrs.name`.

### Non-DB tests

```elixir
use ExUnit.Case, async: true         # e.g. Substitution, pure logic
use ExUnitProperties                 # StreamData property tests (installed)
```

### Mocking

Mimic is available. Prefer integration tests through real changesets over heavy mocking.

### Flaky tests

A test that fails and then passes with no code change deserves investigation.
Keep the failed run's evidence and compare the commits, workflow conditions,
runner environment and external dependencies before calling it a flake.
**File confirmed flakes.** Record an unexplained failure with what you know
rather than dismissing it because a rerun passed.

```bash
gh issue create --label flake --label area:testing --title "Flake: <what raced>"
```

`flake` is the label every one of them carries; `area:testing` and the area
the test covers go alongside it. Search before filing —
`gh issue list --label flake --state all` — because the same flake gets found
repeatedly and a second issue splits the evidence.

File rather than fix in place when you are mid-task on something else, so a
campaign's diffs stay about the campaign (#1539). Fix it in place when it was
your own change that flaked.

What the issue needs, because a flake nobody can reproduce is a flake nobody
can close:

- the failing assertion with its `left:`/`right:`, and the file and line;
- **how often, out of what** — "one full-suite run in eight", "four
  first-attempt CI failures this week" — with the run URLs;
- the mechanism if you have it: what the test asserts on versus what it waits
  on. That difference is the whole bug in most of them.

Two places to investigate are failed first attempts followed by successful
reruns, and failed `push` runs on `main`. This query finds rerun candidates;
a successful later attempt alone does not establish why the first failed:

```bash
gh run list --workflow ci.yml --limit 200 \
  --json databaseId,attempt,conclusion,headBranch --jq '.[] | select(.attempt > 1)'
gh api /repos/managoat/fountain/actions/runs/<id>/attempts/1/jobs
```

A green PR does not prove that a failed post-merge run is a flake. The merged
tree can include other changes, push-only jobs can test different behavior,
and the runner or external services can differ. Compare those conditions
before classifying the failure. Before filing from either source, date the
failure against `git log` on the file a fix would touch: of four found this
way on 2026-09-04, two had already been fixed after the failed run.

## Things NOT to do

- **Don't reach for `_unsafe_*` without established ownership.** These skip tenant scoping; the legitimate caller shapes (including the scoped-parent-fetch-then-`_unsafe_`-child pattern) are in the tenant isolation section above.
- **Don't lower the test pool size below 20.** Pool exhaustion causes flaky timeouts.
- **Don't remove `:ueberauth_test_mode` or `:rate_limit_test_isolation` from `config/test.exs`.** They're correctness guards, not performance flags.
- **Don't start fire-and-forget work with `Task.async`.** It *links* to the
  caller and nothing awaits it, so a transient failure in a write nobody wants
  the result of takes the request process down — and under the SQL Sandbox that
  process is the test, which is how a stamp on `last_used_at` failed a
  scheduling test that had already passed (#1040). Use
  `Task.Supervisor.start_child(Fountain.TaskSupervisor, fun)`: unlinked,
  supervised, and a crash is logged. `DataCase` waits for the tasks a test
  started before stopping the sandbox owner, so the write lands rather than
  having its connection pulled away. `Task.async` is right where the caller
  keeps the ref and handles the reply (`Analytics.Sink`).
- **Don't push directly to `main`.** All changes go through PRs; the CI gate must pass.
- **Don't merge past the queue with `--admin`.** Organization admins can still
  bypass, and every bypass lands a tree the queue never tested — which is the
  exact thing it exists to stop, and it also denies main's push the
  `tested-tree` artifact, so the full suite re-runs on main anyway. Use
  `gh pr merge <N> --squash --auto`. `--admin` is for a genuine emergency
  (reverting a broken main), and says so in the PR.
- **Don't wait synchronously for a queued PR to merge.** Queue it and move on;
  a lone PR waits up to five minutes for company before it even builds. Come
  back to it, or watch `gh pr checks <N>`.
- **Don't re-run a red test until it goes green and move on.** Keep the failed
  run's evidence and investigate what changed between attempts. File confirmed
  flakes with the `flake` label, and record unexplained failures with what you
  know — see *Flaky tests* above.
- **Don't add `async: false` to tests unless the test genuinely requires it** (e.g. global ETS state). The SQL Sandbox handles DB isolation.

## Adding a new context

1. Create `apps/fountain/lib/fountain/<context>.ex` with tenant-scoped functions.
2. Add a test at `apps/fountain/test/fountain/<context>_test.exs` with `use Fountain.DataCase, async: true`.
3. Use `_unsafe_` prefix for any admin/internal functions that bypass tenant scoping.
4. If the context handles secrets, use `Fountain.Crypto.load_tenant_key/1` + the pattern above.

## Environment variables

See `.env.example` for the full list. Key ones for local dev:

| Var | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection (defaults to `localhost:5432/fountain_dev`) |
| `MASTER_SECRETS_KEY` | Platform master key for envelope encryption |
| `SPRITES_TOKEN` | Token for the Sprites sandbox platform |
| `GITHUB_OAUTH_CLIENT_ID/SECRET` | GitHub OAuth app |
| `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` | Credit-pack Checkout and the three credit webhooks (`CREDITS_ENABLED=true` only) |
| `RESEND_API_KEY` | Transactional email |

## Docs (`docs/`)

`docs/` is the public manual, published at `/docs` and **nowhere else** — the
markdown is embedded at compile time by `Fountain.Docs`, which is one `use`
line over the `managoat_docs` library (ADR 0037): the macro embeds the pages,
`Managoat.Docs.Markdown` renders them (the sanitising pipeline `/help` and
agent output share; it returns a binary, callers `Phoenix.HTML.raw/1` it),
and `docs_test.exs` gets its structural checks from
`Managoat.Docs.GuardrailCase`. It used to be built as
a MkDocs Material site and deployed to GitHub Pages as well; that copy was
retired in #1008, so there is no `mkdocs.yml`, no `docs.yml` workflow and no
`mkdocs build` step to keep green. A page reaches a reader through `/docs` or
not at all.

**Nothing publishes to GitHub Pages any more.** A tombstone used to answer
the retired MkDocs URLs with one redirect each into `/docs` (#1011). The move
to the `managoat` organization killed it: GitHub Pages does not follow a
transfer redirect, so `binarybourbon.github.io/fountain/` 404s and the host
those URLs name can never answer again. Its generator and workflow were
deleted with #1814. Do not build a second publisher for the manual; `/docs`
is the only one, and 0034 is the standing decision that says so.

Guardrails that trip people who only edit markdown:

- **An extension may own pages** (ADR 0043, #1510). They live in
  `apps/<app>/docs/` with that app's own `nav.yml`, embedded by its own
  `use Managoat.Docs` module and merged into the sidebar by `Fountain.Manual`,
  which is what every renderer asks instead of `Fountain.Docs`. Sections merge
  by title, so a moved page keeps its place. A **core page must not link to
  one** — `Fountain.DocsTest` walks the core manual alone and a core-only
  distribution would have a dead link; the extension's own suite runs the link
  checks over the merged manual.
- **The nav lives only in `docs/nav.yml`.** `Fountain.Docs` parses that file's
  `nav:` block at compile time, so adding, renaming or moving a page is a
  one-file change. It used to be mirrored in `@nav` in
  `apps/fountain/lib/fountain/docs.ex` with a drift test, which is exactly how
  docs-only PRs kept going red in *partition 3* of CI, looking unrelated to
  the docs. Keep to the two line shapes the parser reads — `  - Title: x.md`,
  and a `  - Section:` header with six-space-indented children — because a
  line it cannot read raises at compile time rather than being skipped.
  **Sections are one level deep.** The in-app sidebar renders exactly a section
  and its pages, so a sub-section (or a page indented past its siblings) raises
  too. Flatten it into a sibling section — `Catalog` is what that looks like,
  with the three hub pages sitting among their own entries — or make it
  headings on a hub page.
- **A page not in the nav is published nowhere.** `docs_test.exs` walks
  `docs/**/*.md` both ways: every page the nav names exists, and every page on
  disk is named. There is no allowlist. If a markdown file should not be read
  at `/docs`, it belongs somewhere else — `decisions/` and `standards/` are
  deliberately unpublished. MkDocs used to build an unlisted page anyway, so
  four planning pages accumulated under `docs/superpowers/` before this check
  existed (since deleted).
- **Anything `Fountain.Docs` reads at compile time must be `COPY`d into the
  Docker build stage.** The release image contains no `docs/`, only strings
  baked out of it, so a file outside the `COPY` list does not degrade to a
  broken link: `mix release` dies, no image is built, CI stays green and the
  deploy silently never happens (#884). `docs_test.exs` asserts the module's
  `external_resources/0` (every `@external_resource` the `use` declared)
  against the Dockerfile, so adding a new compile-time read fails there
  first. A file outside `docs/` goes on the `extra_resources:` line of
  `Fountain.Docs`, which is how `CHANGELOG.md` is declared.
- **Links and anchors are checked by the suite, not by a site build.** Every
  internal `/docs` link must resolve to a page, and every `#anchor` to a
  heading on that page. `mkdocs build --strict` used to carry the link half of
  this on `main` only; `docs_test.exs` carries both, on every PR, and it is the
  stricter of the two — MkDocs never checked anchors. Run
  `mix test apps/fountain/test/fountain/docs_test.exs`. The checks themselves
  are `Managoat.Docs.Checks`, functions returning failure messages, and
  `GuardrailCase` is what turns them into the tests in that file; the
  library runs the same template against a fixture manual, so a change to a
  check is tested there before it runs against `docs/`.
- **Wording checks advise; structural checks block.** CI retains the full
  wording reports as `prose-advice` and caps each log at 60 lines. The style
  standards still guide writing; their heuristics do not block unrelated fixes.
- **`python3 scripts/docs-style.py`** checks the style sheet
  (`standards/voice-and-style.md`): no em dashes, no colon-introduced
  lists, no "simply"/"obviously"/"coming soon". It skips the backlog in
  `scripts/docs-style-allow.txt`, so a file **not** on that list is checked and
  every new page is covered by default. Cleaning a page means deleting its
  line; the list only shrinks (#911).
- **`vale lint docs $(ls -d apps/*/docs)` checks ASD-STE100 Simplified
  Technical English.** An extension's slice of the manual (ADR 0043) is held to
  the same report; vale selects from its path arguments, so those directories are
  named explicitly, while `docs-style.py` and `destink.mjs` discover them. Every
  published page is written in it. The standard is
  `standards/simplified-technical-english.md`; config is
  `.vale-ste.yml`; the backlog is `.valeignore` and is **empty**. The linter is
  [`stuffbucket/vale`](https://github.com/stuffbucket/vale) — MIT, pure Go.
  Install it with `brew install stuffbucket/tap/vale`. CI uses the pinned
  `v0.15.0` release binary, checksum-verified, **not** `go install`: the jobs
  pin Go from `cli/go.mod` with `GOTOOLCHAIN=local` and cannot fetch the newer
  toolchain the module wants. The gate is six rules: sentence length (20
  procedural / 25 descriptive), contractions, the passive voice, phrasal verbs,
  one instruction per sentence, and the -ing form. `STE.Vocabulary` advises and
  does not gate, because its wordset was built for aircraft maintenance. Read
  the standard before you fight the linter — it lists the three traps (joined
  table cells, a code span opening a sentence, `anything` matching the -ing
  rule) and where a suppression comment is legitimate.
- **`node scripts/destink/destink.mjs` looks for AI-writing tells.** The third
  prose report. The engine is the published
  [`sentences`](https://github.com/lex00/sentences) package (MIT), pinned by
  the version range in `scripts/destink/package.json` — bump it and run
  `npm install --prefix scripts/destink` to pull in an upstream change.
  `scripts/destink/allow.txt` is the backlog and is **empty**, like the other
  two. Two things to know before fighting it:
  - **It lints prose, not markdown.** The package's `lint/markdown-prose`
    export blanks code fences, tables, inline code, link targets, HTML blocks
    and admonition directives, replacing each character with a space so every
    offset still indexes the real file. Run whole over raw markdown the linter
    reported 2,721 findings, of which ~1,750 were markdown mistaken for
    writing: `--` in a CLI flag read as an em dash, table rows read as
    sentence fragments, and `guides` and `operate` read as words because they
    sat in a URL. If a finding points at something that is not prose, the fix
    belongs upstream in `lint/markdown-prose`, not in the page.
  - **The rule set is opt-in, and each entry carries its count.** `ENABLED` and
    `DISABLED` in `scripts/destink/destink.mjs` list all 46 rules with the
    number each produced over `docs/` and, for the disabled ones, why. Opt-in
    is the safety property: a rule added upstream between versions arrives
    off. The gate refuses to run if an id named there is missing from the
    package's registry, which is what a rename upstream looks like from here.
- **`docs/cli.md` is diffed against the CLI.** `cli/internal/cmd/docs_test.go`
  fails if a command exists that the page does not mention, or the page
  mentions one that does not exist. Add a CLI command → add it to `docs/cli.md`
  in a fenced `bash` block.

The dialect the renderer understands is small (snippet includes, admonitions,
relative `.md` links) and is inherited from the MkDocs site these pages used to
be; check a page at `/docs` if it uses anything fancier. Nothing else renders
them, so `/docs` is the answer, not a second opinion.

## Decisions

Architecturally significant choices live in `decisions/NNNN-<title>.md`. When a decision is contentious or needs to constrain future work, write an ADR. Use `decisions/0001-template.md` as the template.

`decisions/` is an [OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) bundle. Start at `decisions/index.md`, which lists every ADR with its status, whether it has been verified against the code, and when its status block goes stale. Each ADR's frontmatter carries `adr_status`, `verified` and `stale_after`; the template explains the fields. CI runs `okf validate decisions` and regenerates the index (`scripts/decisions-index.sh`), so a new ADR needs frontmatter and an index refresh in the same PR; run both locally before pushing. `okf backlinks decisions <id>` lists the ADRs that depend on one before you amend it. The `okf` CLI is a single Go binary from [okfcli/okf](https://github.com/okfcli/okf): `brew install okfcli/okf/okf`, or `go install github.com/okfcli/okf/cmd/okf@latest`, or the pinned linux tarball the workflow downloads (`.github/workflows/decisions.yml`). Every command prints JSON; `okf schema` describes them all.

**ADRs and docstrings must not describe unbuilt behavior as existing.** The 2026-07 audit found three mechanisms asserted as implemented (a quota check, metering call sites, a gate backstop) that did not exist — anyone reading the ADRs concluded the system was metered, capped and gated when it was none of those. If a document describes behavior that is not yet in code, say so explicitly (`**Status:** Proposed`, "not yet built"), and remove the caveat in the PR that builds it.
