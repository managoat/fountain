# Changelog

All notable changes to Fountain are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

Pre-1.0, a minor bump (`0.x` → `0.y`) may include breaking changes; when one
does, the release carries an **Upgrade notes** section. Patch releases are
always safe to take. Every release publishes the server image to
`ghcr.io/binarybourbon/fountain` as `vX.Y.Z` (immutable) and `vX.Y` (moving,
newest patch in the line). The full policy, including how migrations run on
upgrade, is in
[Versioning and upgrades](https://fountain.inevitable.fyi/docs/guides/operate/upgrade#how-versions-work).

---

## [Unreleased]

### Upgrade notes

- **Connections needs no `FEATURE_FLAGS_ON` entry on a deployment without
  PostHog** (#1693). Gating Connections behind the `connections` flag (#1620)
  took the feature away from every deployment that configures no flag service,
  because a flag nobody can answer reads off. The flag now reads **on** where
  `POSTHOG_PROJECT_API_KEY` is unset, so an upgrade keeps the Connections page
  and the `/api/connections`, `/api/connection-providers` and
  `/api/secret-bindings` routes. An operator who set
  `FEATURE_FLAGS_ON=connections` to get the feature back can drop it, and
  nothing changes where PostHog is configured: it answers the flag as before,
  and `FEATURE_FLAGS_ON` still wins over both. The switch that turns
  Connections off is the broker: an account is offered the feature only while
  `BROKER_TENANTS` names it.

### Added

- `POST /api/conversations/:id/reapply` re-selects a conversation's Agent,
  Environment and Vault on the machine it is already running, keeping the
  conversation, its transcript and the files on its disk. A selection that would
  need the machine built again is refused, naming what forced it. Adds the
  `configuration` webhook stage and three columns
  (`conversations.configuration_revision`, `sandboxes.build_fingerprint`,
  `sandboxes.applied_skills`) (#1565).

### Changed

- **Brokerage is a property of the deployment, and the per-tenant ratchet is
  gone** (ADR 0019 §9, amended 2026-09-12). `Fountain.Broker.enabled_for?/1`
  and the `:broker_tenants` configuration are removed, and
  `Fountain.Broker.configured?/0` is the whole gate. This deletes sixteen
  `if brokered?(user_id) do ... else ... end` branches across `Egress`,
  `Connections`, `SecretBindings`, `ConversationServer`, `SpriteEnv`,
  `PlatformInference` and the web layer, each of whose `else` arm was an
  unreachable plaintext-credential path after the 2026-09-04 flip to `*`.
  `Egress.brokered?/0` and `Connections.manageable_for?/0` lose their tenant
  argument; so do `Egress.split_brokered/2`, `split_inference/3`, `release/1`,
  `reattach_policy/3` and `Lifecycle.destroy/4`. The `/admin/broker` page drops
  its "Brokered tenants" tile. The two non-broker paths that remain are the
  `BROKER_LISTEN_PORT` off switch (#2056) and the `BROKER_ALLOW_UNENFORCED`
  arm that decides whether a self-hosted runner can host a brokered
  conversation (#2057); both are open decisions, named in the ADR.

- **`sprite_name` on `POST /api/conversations` is now a suffix, not the whole
  machine name.** The server keeps the `fountain-<account>-` prefix every
  generated name already carried, so a name a caller chooses lands in their own
  namespace instead of anywhere in the provider's. Provider names are unique
  per deployment token rather than per tenant, and the Sprites adapter adopts a
  name that already exists, so the previous verbatim behavior let two sandbox
  rows in two accounts point at one machine. Three changes go with it: a name
  that already carries this account's prefix is taken as it stands (a name from
  an earlier launch still resolves to the same machine); a suffix outside
  `[A-Za-z0-9][A-Za-z0-9_-]{0,39}` answers `422 invalid_sprite_name` rather
  than reaching a provider; and `sprite_name` is refused with
  `sandbox_api_access: "none"`, and on an agent that runs on a self-hosted
  runner (`422 sprite_name_not_supported`), where the name carries the runner
  it is placed on. On that provider the name was also a routing decision with
  no tenant check, because the runner adapter reads the runner id out of the
  name and looks the connection up by that id alone, so a name shaped like
  another account's runner sandbox sent the launch to their runner.
  All four SDKs expose the field and need no change.
  **Upgrade note for anyone who passed `sprite_name`:** existing sandbox rows
  keep their old names and are not migrated, and passing the same value now
  mints a *different* machine under the account-scoped name. A caller who
  passed `my-box` has a row named `my-box`; passing `my-box` today provisions
  `fountain-<account>-my-box` and answers 201, leaving the old row untouched
  and no longer reachable by the name that created it. A name that already
  carries this account's prefix still round-trips, so a name minted by the
  server keeps resolving to its own machine; an arbitrary legacy name does
  not, and the way back to that machine is `sandbox_id`, which attaches by row
  rather than by name. `sandbox_id` reaches the row while it is attachable
  (ADR 0023), so a machine that was reaped, has a reset pending, or belongs to
  a different agent, vault, environment or runtime than the launch answers 409
  or 422 rather than attaching.

- **The claude runtime's ACP adapter moves to 0.75.1, and a fresh sandbox now
  warms the CLI's model list before its first session** (`managoat_runtimes`
  0.3.4). The adapter bundles the Claude Code binary that decides which models
  a turn may select, and 0.66.0 bundled CLI 2.1.220; 0.75.1 bundles 2.1.257,
  which also resolves a full model id onto the alias row the CLI advertises
  rather than matching it exactly. Separately, that binary learns an org's
  "additional models" from a fetch it makes *after* a session has started and
  caches the answer for the next launch, so the first session in a fresh
  sandbox saw a shorter list than the second one in the same sandbox — which
  is what made a model refusal look intermittent. Provisioning now opens one
  prompt-less session to fill that cache, under three seconds measured and
  bounded at 30. It is best-effort: a cache that stays cold is logged and
  provisioning continues.

- **The project moved to `github.com/managoat/fountain`** and every coordinate
  that named the old owner moved with it (`decisions/0048`). The container
  image is `ghcr.io/managoat/fountain`, the Homebrew tap is
  `brew install managoat/tap/fountain`, and the Go module paths are
  `github.com/managoat/fountain/cli` and `.../apps/fountain_buzz/cli`. Old
  URLs redirect, so a clone, a `git remote`, an issue link or a release-asset
  download keeps working; the published image tags `v0.16.0` and `v0.16` exist
  at both paths. Two things do not follow a redirect and need an edit:
  `go install` of the old module path now refuses with a module-path mismatch,
  and the retired GitHub Pages doc URLs under the old account are gone.

- **The TypeScript SDK is published as `@managoat/fountain-sdk`.** Same library
  and version line; `@agentshit/fountain-sdk` keeps its published versions and
  receives no new ones. See `sdk/typescript/CHANGELOG.md`.

- A sandbox reset is fenced until the provider confirms the deletion. The
  fence commits before any provider call, so no turn starts on a machine that
  is on its way out, and the quota slot stays held until the delete is
  confirmed rather than released on an unconfirmed one. A second reset, an
  attach and a wake all answer `409 sandbox_reset_pending` instead of sending
  another delete. Only a `ready` or `suspended` machine resets now; `pending`
  and `starting` answer `409 sandbox_not_resettable`, because a machine still
  under construction has no disk to replace. A reset that the provider does
  not confirm records `sandbox.reset_requested`; `sandbox.reset` now means the
  delete succeeded. To clear an unconfirmed reset, reap the sandbox from the
  admin sandbox list. That retires the row and releases the slot; the machine
  at the provider is then the operator's to check.

- `POST /api/conversations` refuses an opening prompt it cannot use, before it
  reserves a sandbox or creates the conversation. Whitespace-only text and a
  non-string prompt return `422 invalid_prompt`. Images sent with no opening
  text return `422 invalid_prompt` as well; previously such a request was
  accepted and provisioned a machine that received pixels and no instruction.
  An image whose `media_type` is unsupported, whose decoded bytes are empty, or
  which exceeds the 10MB ceiling returns `422 invalid_images`. The OpenAI-
  compatible endpoint is unchanged: it still synthesizes a caption for an
  image-only message, because clients of that dialect cannot always send one.

- **`truncated` on a sandbox file or diff now means "this is not the whole
  thing", not "the cap was reached"** (#1907). On
  `GET /api/sandboxes/:id/file` and `GET /api/sandboxes/:id/diff` it is still
  true when the file or diff is longer than `max_bytes`, and it is now also
  true when redaction grew what was read past that cap — which happens when
  `[REDACTED]` is longer than the value it stands in for. So a file that fits
  `max_bytes` can come back `truncated: true` with its content cut. The
  widening errs safe: `truncated: false` still means the bytes are complete,
  which is the direction a caller depends on, and the new true case tells a
  caller to ask for more. The field has been published since SDK 1.15.0; its
  description changed with it, in the OpenAPI document and in the generated
  TypeScript types.

### Added

- **An account registers its own OAuth clients** (#1125, ADR 0021 amended).
  "Sign in with Fountain" no longer needs an operator to edit `OAUTH_CLIENTS`
  and redeploy. Register an app in the console under Account, then OAuth apps,
  with `fountain oauth-client create`, or over `/api/oauth/clients`, and the
  response carries the generated `client_id` the app sends. The registration
  also admits the app's redirect origins to `/api`, so one registration covers
  both the sign-in and the calls that follow it and `API_CORS_ORIGINS` needs
  no entry.

  A new client is in **development mode**: it signs in only the account that
  registered it, and every other account gets an error page rather than a
  redirect. That is what makes a self-chosen redirect URI safe, and it is why
  an owner may name a sandbox's HTTPS URL or an `http://localhost` one. A
  loopback URI matches on any port (RFC 8252). Only an operator publishes a
  client for other accounts to use, and only an operator changes or removes it
  afterwards. One account holds at most 25. Registration needs a full-scope
  key, because a client is a standing route to a full-scope key after consent.

  The consent page's `form-action` header now names the one redirect origin
  this request asked for rather than every registered client's.

- **A start that meets a capacity ceiling can wait instead of failing**
  (#1033, `decisions/0042`). Set `queue: true` on `POST /api/conversations`:
  at the tenant sandbox cap or the fleet ceiling, Fountain answers `202` with
  a sandbox request and its position rather than `429` or `503`, and starts
  the conversation when a slot frees. Callers that do not ask keep the error
  they handle today. A teammate schedule's cron firing uses the queue on its
  own, because nobody is there to retry it; the page's and the API's "Run
  now" still gets the refusal. `GET /api/sandbox-queue`,
  `GET /api/sandbox-queue/:id` and `DELETE /api/sandbox-queue/:id` list, read
  and cancel that work. The queue delays the cap and never raises it: ten
  requests per tenant (`SANDBOX_QUEUE_MAX_DEPTH`), one hour each
  (`SANDBOX_QUEUE_MAX_WAIT_SECONDS`), every replay back through the same
  reservation, credit and inference gates, and a full queue keeps the
  immediate error. Starts carrying images or naming a `sandbox_id` never
  queue.

- Wire the prepared bounded execution journal into atomic turn admission,
  tracked adapter setup, guarded ACP callbacks, durable cancellation, recovery
  retirement and parent deletion. Bounded turns skip separate title inference,
  cannot reuse a warm process, and require an ACP reply for success. Public
  enforcement remains disabled pending provider release and complete acceptance.

- Prepare a supervised bounded-command transport that binds provider identity
  before stdin, rechecks journal authority for each write, and retains uncertain
  operations. Successful bounded replies now require connection retirement before
  a fresh successor. Public activation remains gated.

- Commit deadline failure events and delivery jobs with the failed turn. Late
  completion and interruption reuse the original event, and notification retries
  retain its id. Public bounded execution remains disabled.

- Add a supervised execution-deadline coordinator with separate expiration and
  termination task pools. Local task timeouts and restarts retain uncertain
  remote operations. It starts only where `FOUNTAIN_EXECUTION_LIMITS` configures
  a host ceiling, and `FOUNTAIN_EXECUTION_DEADLINE_WORKER=false` turns it off
  anywhere. Public bounded execution remains disabled until session identity,
  event delivery, and lifecycle integration are complete.

- **An `acp` runtime launches a named command, so a deterministic program can
  run as an agent** (#1634). `agents.runtime` accepts `"acp"`, and a new
  `runtime_command` field carries the command it runs. The field is required
  for that runtime and a 422 naming the field on every other one, which
  resolves its own executable from a pinned table. `model` is optional there:
  no inference credential is resolved, no model is pinned on the session, and
  a turn succeeds on an account that holds no API key. Fountain installs no
  adapter for it, and the command owns its own configuration; skills still
  mount, and their path arrives as `FOUNTAIN_SKILLS_DIR`. Everything the
  protocol carries is unchanged, including tool-call blocks on the transcript
  and the SSE feed, `session/cancel` on interrupt, and the agent's permission
  policy. With `CREDITS_ENABLED` the turn is priced by sandbox time alone and
  `turn.usage` is null.

  `runtime_command` is a **free string** rather than an entry in a catalog of
  blessed commands. It is resolved inside the sandbox, under the same
  isolation an environment's `setup_script` already runs under, so a catalog
  would restrict a self-hoster and protect nobody. On a self-hosted runner
  with the default backend that isolation is a directory and the daemon's own
  user, which is what trusted mode already means for a setup script; the
  runtime docs say so beside the field.

  **Client note.** `Agent.model` is now nullable, in the response and in the
  create and update bodies, so an agent converted to `acp` can clear the
  model it no longer uses with `{"model": null}`. In the TypeScript SDK
  `Agent["model"]` is `string | null`, and `AgentRequest["model"]` and
  `AgentUpdate["model"]` are `string | null` and optional. A client that
  assumed a string needs a null check. Nothing else on the wire changed
  shape.

- Prepare the released ACP 0.4, Runtimes 0.4.1, Runner 0.2.2, and Sandbox 0.3
  dependency set for typed execution limits and confirmed session termination.
  Fountain deadline enforcement remains disabled pending transport and lifecycle
  integration.


- Environment `setup_timeout_seconds` (1–900, default 120) lets cold repository
  toolchain setup run within an explicit bound. It persists through API/spec
  round trips and invalidates checkpoints when changed. The overall provisioning
  deadline and failed-setup handling remain in force.

- `claude-fable-5-1` is suggested for anthropic again, so `GET /api/catalog`
  lists it. It was removed on 2026-09-07 because the claude adapter refused
  it; the refusal was not the adapter version but a cold cache. The Claude
  Code binary learns an org's "additional models" (Fable among them) from a
  fetch it makes after a session starts and caches for the next launch, so
  the first session in a fresh sandbox never listed Fable on any adapter
  version. Two `managoat_runtimes` releases fix that: 0.3.3 moves the adapter
  pin to 0.75.1 (the bundled CLI must be 2.1.255 or later for Fable 5.1), and
  0.3.4 warms the cache at provisioning. Verified with a real turn on the new
  pin. `claude-fable-5` stays unsuggested: the adapter refuses it even with
  the cache warm.

- Vault secret expiry can be edited in the console or with a metadata-only PATCH, without replacing the encrypted value.
- Conversation lists accept a `sandbox_id` filter, including through the TypeScript SDK.

- `sandbox_api_access: "none"` on conversation creation omits the Fountain
  sandbox callback credential before provisioning and on every wake. It requires
  a fresh ephemeral sandbox, is immutable, and refuses machine sharing and
  channel resumes with a different setting. The catalog advertises support;
  existing launches retain `owner` behavior. Applications processing mutually
  untrusted work can keep all Fountain API authority on their service host.

- A `fountain apply` manifest can declare webhook endpoints. A `Webhook`
  document is keyed by its `spec.url`, and the apply that creates one hands
  back its signing secret on that result row and never again. A manifest that
  holds a `Webhook` needs a full-scope credential, which is what
  `POST /api/webhooks` needs, and a refused request writes none of the
  manifest's other resources either (#1636).

- A `fountain apply` manifest can declare a teammate's schedules. A `Schedule`
  document names its teammate, its cron and its prompt, and is keyed by name
  under that teammate. A teammate name that two teammates answer to fails that
  row rather than binding to one of them (#1636).

- A `fountain apply` manifest can declare team membership. A `Teammate`
  document names its agent, environment and vault, and the apply puts the agent
  on the team, which opens its conversation and provisions its computer.
  Re-applying moves the name and the bindings and provisions no second
  computer (#1636).
- Conversations carry free-form `labels`, a map of at most 32 key/value
  strings. Set them on creation or with `PATCH /api/conversations/:id/labels`,
  which merges. A running agent stamps its own conversation with the
  `_fountain/labels` ACP extension notification, and a sandbox callback token
  can label only the conversation it was minted for, on every door that writes
  labels. `GET /api/conversations`
  and `GET /api/team/:agent_id/conversations` take a repeatable `label=key:value`
  filter, combined with AND. `conversation.*` webhook payloads carry `labels`,
  and the console's conversation lists render them as chips.
- Permission requests can outlive the turn that raised them. An agent that ends
  a turn with stop reason `waiting` keeps its request open, the conversation
  goes idle and the sandbox suspends as usual. `GET /api/conversations/{id}`
  lists such requests as `pending_requests`, and answering one opens a new turn
  carrying the request id and the chosen option, which wakes the sandbox. The
  wait is bounded by `_meta.fountain.timeout` on the request and by an
  `ask_timeout` in the permission policy, the shorter of the two, else the
  existing 5 minute ceiling, and at most a year either way. An answer is
  refused, and the request kept, when the conversation cannot take the turn
  that carries it.

### Fixed

- A prompt automatically continues once on a fresh session when the runtime's
  saved session is missing. The transcript announces the lost agent memory;
  the conversation history, original turn and execution deadline are preserved
  (#1667).

- Bounded execution transports recheck their absolute deadline before retiring
  a turn. A timer that wakes early no longer interrupts a valid turn or hides
  its eventual wall-time-limit outcome.

- Sandbox `/diff` returns 422 when Git fails after repository discovery,
  instead of reporting an empty diff. Intentional byte-cap truncation still
  succeeds (#1904).

- **A reset refused by a bounded execution says so** (ADR 0046). Deleting a
  sandbox while a bounded turn still owed a remote stop answered `422` with an
  empty body, because `:execution_fenced` had no `FallbackController` clause
  and fell through to the unmapped-atom net, logging a warning on every
  refusal. It now answers `409 execution_fenced` with a message, beside the
  two refusals it sits next to — and unlike `sandbox_mid_turn` (wait for the
  turn) and `sandbox_reset_pending` (contact the operator), this one clears on
  its own once the obligation ages out, which the message says.

- **An account whose `connections` flag is off can revoke what it already
  holds** (#1693). The flag stood in front of every door, the ones that take a
  credential away included, while the runtime kept brokering those same tokens
  into sandboxes: revoking a connection, deleting a provider and unbinding a
  secret each answered 404 for a credential that was still in use. The flag
  now gates only the doors that add one, which are connecting an account,
  defining or editing a provider, binding a secret, pointing a binding at a
  different host and enabling a binding that is disabled. Listing, revoking,
  unbinding, deleting and disabling are open to every account the egress
  broker is on for, in the console and over the API: `DELETE` unbinds and
  `PATCH` with `enabled: false` and nothing else disables. The Gmail MCP
  endpoint serves a connection that already exists the way the rest of the
  runtime does.

- A conversation server that crashes no longer prints its brokered secret
  values, its egress proxy session, its inference credentials, its resolved MCP
  configuration, the sandbox platform token behind the running command, the
  turn's prompt and reply text or the runner reattach buffer into the crash
  report and the Sentry event (#1690). Those fields held plaintext and were
  outside the redaction that covers the sprite environment, the tenant key and
  the callback token. A guard now fails for any new server state field until it
  is either redacted or recorded as safe to print.

- A teammate can be moved to a different environment or vault. Fountain retires
  the computer the old binding named, so the teammate's next message builds one
  from the new pair, and it refuses the move while a turn is running on that
  computer. A move onto an environment and vault the agent already has a
  computer for is refused rather than merged onto it (#1636).

- A conversation that shares a sandbox follows the replacement machine only
  when it declares the same environment and vault. The replacement is built
  from the waking conversation's pair, so a co-tenant that named a different
  one was run on another conversation's environment files and vault material,
  and which pair won depended on which conversation woke first. One that names
  something else now keeps its own pair and builds a machine from it on its
  next prompt (#1636).

- A resource in a `fountain apply` manifest that raises unexpectedly now fails
  its own result row instead of the whole request. Before, the exception
  abandoned a call that had already written the resources above it, so the
  caller got a 500 and no result rows for writes that had landed (#1636).

- Updating an environment, vault, agent or webhook endpoint with the values it
  already holds no longer records an `*.updated` audit event naming no changed
  fields, and `fountain apply` reports those rows as `unchanged` rather than
  claiming an update. A re-apply of the same manifest now writes nothing and
  says so (#1680).

- A secret edited or rotated in an environment or vault during a brokered
  conversation reaches the broker before the next turn. The broker's copy was
  split once, at provisioning, and only the tenant's connection tokens were
  read again; a change also minted a new session, whose token reaches only the
  next spawned process, while the idle agent that carries the next turn kept
  the old one. Now the environment and vault are read before every turn and
  the live session's rules are rewritten in place, token kept; when a token
  does have to be replaced, the idle agent is closed so the next turn spawns
  with it. A client that writes a fresh one-hour GitHub App token into a
  vault before each prompt no longer sees `401 Bad credentials` an hour in
  (#1736).

- ACP token/request limits and unknown stop reasons now fail the turn instead
  of reporting completion. Reported usage and the original stop reason remain
  available; only `end_turn` establishes normal completion (#1732).

- The broker's root CA is installed under a lock, and the operating-system
  trust store is rebuilt only when the bundle on the machine is not the one
  that CA produces. Conversations sharing a sandbox each ran
  `update-ca-certificates`, which builds the bundle at a fixed temporary
  path, so two runs at once published a truncated one. A client that read it
  in that state trusted no broker root and failed every request with
  `UnknownIssuer`. A sandbox whose bundle is damaged, whether before this
  change or afterwards by a package install or a setup script, repairs itself
  on its next provision or wake (#1674).

- An environment's `env_vars` can override the broker's CA variables
  (`SSL_CERT_FILE` and the rest). They were written before the broker's own,
  so a value set for one of those names silently did nothing. The proxy
  variables still win over everything: they are what makes egress brokered.
  Both halves of the rule are now in the manual, under Secrets (#1674).

- A brokered Codex conversation reaches OpenAI over a provider with the
  WebSocket transport turned off. Codex's `responses_websocket` dialer cannot
  use an https-scheme proxy and spent the full connect timeout finding that
  out — around 300 seconds on every turn, before falling back to HTTP and
  answering in about a second. The built-in `openai` provider is reserved and
  cannot be overridden, so Fountain declares the same endpoint under an id of
  its own, carrying across `OPENAI_BASE_URL`, the OpenAI-Organization and
  OpenAI-Project header mappings and standalone web search. A
  conversation whose spawn has no `OPENAI_API_KEY` keeps the built-in
  provider, which can still authenticate from `~/.codex/auth.json`. An agent
  that names its own provider in `CODEX_CONFIG` keeps it; a `model_provider`
  written into `~/.codex/config.toml` by a setup script is not read, and is
  overridden (#1674).

- Codex launches on Sprites with inherited and ambient capabilities cleared,
  allowing its bubblewrap sandbox to start without falling back to approval
  escalation on every command (#1672). Existing adapter processes need a restart.

- Reattach and idle-process cleanup recover conversation identity from a Sprites
  process's environment after its command changes. Unidentified processes are
  never selected by list order on a shared sandbox. ACP updates from another
  session are discarded and foreign permission requests are cancelled before
  policy evaluation (#1658).

- A runtime confirming a model in its own canonical designation is no longer
  read as a substitution (`managoat_acp` 0.2.2). Claude's adapter accepts
  `claude-opus-5` and confirms `opus`, and `claude-sonnet-5` and confirms
  `sonnet`; strict equality failed those turns before any prompt was written,
  so every claude agent stopped answering while codex, which echoes the id
  verbatim, kept working. A confirmation naming a genuinely different model
  still fails the turn, as does an outright refusal.

- The model catalog no longer suggests ids the pinned ACP adapters refuse.
  `claude-sonnet-4-6`, `claude-opus-4-7` and `claude-opus-4-8` are refused by
  `claude-agent-acp` 0.66.0, and `gpt-5.3-codex` by `codex-acp` 1.10.0. All
  four answer a real inference call, so the provider check that vets this list
  passed them; the adapter refuses them at `session/set_model`, before a prompt
  is written. Since the model enforcement in the previous entry a refusal fails
  the turn, so a suggested id the adapter refuses is an outage rather than a
  stale hint. `gpt-6-astra` is listed for openai. A test pins the refused set
  so none of them can be relisted from a provider check alone.

- The new-agent form no longer starts you on a model the adapter refuses. Its
  prefilled model was `claude-sonnet-4-6` and its codex placeholder
  `gpt-5.3-codex`, so opening New agent, typing a name and saving produced an
  agent that failed every turn at `session/set_model` — the form's own hint
  ("Not one of the models Fountain lists") was firing on the value the form
  supplied. The catalog clean-up in the previous entry reached the suggestion
  list only; a default is what you get by doing nothing and a placeholder what
  you get by typing the hint, so both are stronger claims than a suggestion.
  Defaults, placeholders and the starter agent every verified account owns are
  now held to catalog membership, which also catches a *retired* id — the way
  `gpt-5-codex` went stale on 2026-08-22 — and not only a refused one.

- `claude-fable-5-1` is no longer suggested for anthropic, so `GET
  /api/catalog` no longer lists it. It was added on 2026-09-06 from Anthropic's
  published model id, and the pinned `claude-agent-acp` refuses it at
  `session/set_model`. No saved agent used it. `claude-fable-5` is refused the
  same way and was never suggested; both are recorded so neither can be
  relisted from a provider check alone.

- The account event stream replays rapid failures missed before discovery and includes finished conversations on reconnect.
- Registration and conversation creation declare both shapes of 422 refusal without schema-guard exceptions.
- A scoped fetch reads a malformed id as nil rather than raising out of the query, so a path segment or header that is not an id answers 404 where it used to answer 500 with a dropped connection. An id field that a caller fills with something other than a uuid is refused by the changeset, naming the field and the value. A vault name in an agent's `allowed_vault_ids` through `POST /api/apply`, where the document spec is free-form, reached the database layer and answered with a 500 and a dropped connection. A parent conversation header that is not an id is now the same 404 an unknown parent already gets.

### Changed

- OpenAPI operations declare shared pipeline failures and controller refusals. The schema guard no longer exempts missing response statuses.
- The API manual is a workflow guide linking to the generated reference at `/api/docs`; existing section anchors remain available.
- Portable Prometheus rules cover stage and reattach failures, per-provider turn failure rates, and slow first output. Thresholds have executable alert fixtures.

- Manifest apply rejects unknown `spec` keys before writing that resource or its secrets. Previously, Ecto silently discarded them, including misspelled network restrictions. Correct these keys before upgrading. Bulk apply keeps its HTTP 200 response with per-resource errors; other valid resources still apply. Ownership keys remain ignored.

- **Credential brokerage is on for every account on the hosted platform**
  (ADR 0019 §9, home-cloud#163). It was limited access, enrolled by hand, and
  named one tenant from 2026-08-25. The docs said so on six pages; they now
  say what is true. `BROKER_TENANTS` is `*` there, the wildcard #1553 added.
  Nothing changes for a self-hosted instance, where the broker stays off
  until an operator sets `BROKER_LISTEN_PORT` and names tenants.

  The reason to widen was the inference credential rather than tenant
  secrets. Gate 3 covers every conversation, so the platform's own keys stop
  entering a sandbox in the clear for everyone at once; at the time of the
  flip every brokerable tenant secret in the deployment belonged to one
  account and `secret_bindings` was empty. `Feature status` now lists two
  features rather than three.

### Added

- **An application can start a computer before its visitor has an account, and
  the visitor keeps that exact computer when they register** (#1551, ADR 0044).
  A **claimable principal** is a `users` row with no identity, opened by a
  trusted application over `POST /api/claimable-users` and funded out of that
  application's own credit balance. It is a full tenant from its first request
  — its own DEK, agents, environments, vaults, conversations and sandboxes, all
  scoped away from every other principal — and it comes back with a
  `principal`-scoped API key plus a one-time claim token.
  `POST /api/claimable-users/:id/claim` attaches a registered account as the
  principal's owner and **moves nothing**: the sandbox, the disk, the agent, the
  conversations and every id survive the claim, because the tenant id is what a
  sprite name is built from and a resource-by-resource transfer would hand the
  visitor a different machine. Both a brand-new account and one that already
  owns work claim the same way, since an owner may hold more than one principal.
  The new scope is deliberately narrow: a principal reaches the resource
  surface a computer is built from and nothing behind `:require_full_scope`, so
  it cannot mint a credential, buy credit, widen its own limits, or see another
  principal. Money follows the owner without a ledger row moving — an unclaimed
  principal spends the application's introductory grant, a claimed one spends
  the account's balance. `GET /api/claimable-users/:id` is the reconcile route
  for an application that lost a response, `DELETE` abandons a grant and
  refunds what it still holds, and an unclaimed grant expires on its own with
  the same teardown. Guide: **Start before sign-in**.

- **`BROKER_TENANTS` takes `*`, so the ratchet has an end state** (ADR 0019
  §9). The variable was a comma separated list of user ids and nothing else,
  which is what made widening deliberate: an operator adds one id, proves it,
  and adds the next. That is the right shape for a rollout and the wrong
  shape for its conclusion, since the only way to say *everyone* was to
  enumerate every account and to keep enumerating each new one. `*` on its
  own now means every tenant. Blank still means nobody, and still is what
  keeps the listener inert on a deployment that turns it on without naming
  anyone. The wildcard is parsed to the atom `:all` rather than kept as a
  member of the list, and a `*` mixed into a list is a boot error: as a list
  member it would broker exactly one tenant whose id was the string `"*"`,
  while reading at a glance like it brokered all of them.

  One thing does not change, and it is the reason to read this before setting
  it. A provider with no `:network_policy` capability still cannot host a
  brokered conversation, because the `allow: [broker]` floor is what makes a
  placeholder worthless off the box. Self-hosted runners advertise
  `[:suspend, :attach]`, so `*` refuses every conversation placed on one with
  `{:broker, :backend_lacks_network_policy}`. `BROKER_ALLOW_UNENFORCED` is
  the development escape hatch and remains the wrong answer in production.

- **The credit workers report on themselves, and money movement is measured
  at the ledger** (#1169). Under ADR 0031 the balance is the gate, so
  `CreditPricer`, `CreditExpirer` and `Credits.Rent` are load-bearing, and the
  only thing watching them was `FountainObanJobsRaising` — which needs a job
  to *raise*. A pricer that ran happily and priced nothing (a bad rate config,
  an empty `SandboxUsage`, a query matching zero rows) tripped nothing, and
  the failure mode is free compute with no signal. Two events answer the two
  different questions. `[:fountain, :credits, :worker, :run]` carries a
  wall-clock `last_run_unix` per worker, so a rule can alert on staleness and
  on a worker that never fires at all. `[:fountain, :credits, :posted]` is
  emitted by `Credits.post/4` at the ledger write, tagged by reason, so cents
  burned cannot drift from the ledger and one event covers turns, inference,
  messages, rent, expiry, grants and purchases. Stripe webhook rejections and
  failures are counted by coarse kind, and email delivery by outcome — the
  latter needs no call-site change, because Swoosh already spans every
  delivery. The per-replica gauge trap applies to `last_run_unix`: it exists
  only on the pod that ran the job, so every rule over it needs `max`.

- **Hosted Buzz agents are bounded and gated** (#1017). Each enabled Buzz
  identity is a supervised `buzz-acp` OS process on Fountain's own pods, so
  the cost is standing rather than metered and `SandboxUsage` reports zero for
  it. One account could stand up unbounded permanent processes, and
  `BootSweep` restarted every one of them on each deploy. Standing up a *new*
  agent now calls `Billing.check_spend/1` and a `BUZZ_IDENTITY_CEILING`
  (default 10), both `402`; a converging deploy of an agent that already
  exists is exempt, because it adds no process and refusing it would strand a
  running harness on stale credentials. `Workers.BuzzHarnessSweep` stops the
  harnesses of an account that cannot spend and starts them again when it can,
  keeping the identity row so a top-up restores the agent intact rather than
  needing a fresh deploy; the boot sweep asks the same question, so a deploy
  no longer undoes it. The admin users table grows a **Slots** column showing
  teammate contacts and hosted agents per tenant, which also renders the
  contact count that had been assigned and never displayed. Pricing the slot
  is still open, deliberately: the ceiling should run for a cycle before
  anyone picks a number.

- **Fountain can sit behind LiteLLM as an OpenAI-compatible upstream.** The
  `examples/litellm-gateway` configuration maps `fountain/<agent>` to every
  agent on an account, forwards `X-Fountain-Thread`, gives long-running turns
  an appropriate timeout, and disables gateway retries. Its smoke script sends
  two turns through LiteLLM and queries Fountain directly to prove both turns
  landed in one conversation. The new gateway guide explains the same setup.

- **`safety_identifier` is a third thread key for OpenAI chat completions.**
  Fountain reads it after `X-Fountain-Thread` and `user`, giving clients behind
  OpenAI-compatible gateways a current body-level fallback when they cannot
  set custom headers. Requests with no key are still rejected.

- **Standalone consumers for the Managoat libraries** (#1365). The
  [`managoat_examples`](https://github.com/managoat/managoat_examples)
  repository has three plain Mix projects with Hex dependencies and no
  Fountain dependency: a local ACP adapter over an Erlang `Port`, an ACP
  session inside `Managoat.Sandbox` with a credential-free Fake path and an
  opt-in Sprites path, and MCP authorization discovery with dynamic client
  registration. Its CI compiles all three with warnings as errors and runs
  the Fake sandbox turn.

### Changed

- **`mix precommit` now assembles the production release** (#1477). It was the
  documented pre-push gate and it could not see a whole class of breakage:
  anything that exists only in `MIX_ENV=prod`. `apps/fountain` scopes the
  OpenTelemetry family `only: :prod`, so `chatterbox` — reached through
  grpcbox under `opentelemetry_exporter` — is in no dev or test dependency
  graph, and when the hackney 4 bump pulled in `h2` with the same four module
  names, `mix release` refused to assemble while compile, format, credo,
  sobelow, dialyzer and all 4,117 tests stayed green (#1472). The new step is
  the assemble alone, not CI's boot check: duplicate modules and the
  application-mode validation are decided at assemble time, and assembling
  needs no secrets, because `mix release` copies `config/runtime.exs` in as a
  config provider rather than evaluating it. It costs ~9s in a warm tree; a
  fresh checkout pays one prod compile (~2 min) and then caches it under
  `_build/prod`.

- **The connection and the transcript have left `ConversationServer`, and the
  server is what is left** (#1377, tracker #1369, last). The ACP connection
  that outlives the turn (#817) is `Fountain.Conversations.Connection`: the
  peer, its monitor, the command underneath it and the quiet timer that closes
  a background cycle (#1301), with the functions that reuse the connection,
  close it, lose it and open an autonomous turn. What the sandbox says on its
  way to the transcript is `Fountain.Conversations.Output`: the durable log
  budget (#331), the truncation marker, the reattach replay skip and the stage
  events. The server keeps the process — `init/1`, the provisioning watchdog,
  the reattach orchestration, the callbacks, and the terminal paths that end a
  turn. No stage, log line, telemetry event, timer or audit event changed. The
  pin drops from 3,048 to 2,835, and the tracker closes.

### Fixed

- Stop ACP turns before inference when an explicit model is rejected or cannot
  be selected. Apply saved model changes to reused sessions and expose per-turn
  model selection evidence in the API and stream.

- The CLI displays published code changes with their URL, and renders unknown system notices as a dim line.
- `/api/auth/me` now returns the presented API key's `expires_at`, or null for a key without an expiry, as its schema declares.

- Deduplicate database gauges across replicas in sandbox, conversation and Oban alerts.
- Label turn duration and first-output metrics by sandbox provider so hosted alerts can exclude self-hosted runners.

- **ACP `session/new` carried the agent's unsubstituted MCP configuration**
  (#1404). Fountain resolves `${VAR}` references once at provision and writes
  the sandbox's `.mcp.json` from the result, but the turn path re-read the
  agent row on every prompt and sent *that* — the stored document, escapes
  and all — as `session/new.mcpServers`. The session copy wins in Claude
  Code, so a conversation-authenticated HTTP MCP server declared
  `Bearer $${FOUNTAIN_TOKEN}` received `Bearer $ftn_…`: the runtime expanded
  the inner reference and left the escape behind, and Salon had to strip the
  stray `$` at its end. There is one substitution pass and one effective
  configuration now — the resolved document is carried on the conversation
  and is what both the project file and the session get. Resolved values
  still exist only on the live conversation path; the stored agent, API
  responses, logs and audit records are unchanged. `${FOUNTAIN_TOKEN}` and
  `${FOUNTAIN_CONVERSATION_ID}` remain the runtime's to expand from the
  sandbox process environment, which is what keeps a reattached or resumed
  turn on the current credential rather than one frozen into a document.
  Assembling the `session/new` list moved to
  `Conversations.McpServers.for_session/3`, so the server's pin holds at
  2,835 rather than growing.

- **`interrupt` answered `404` for a conversation the caller could see**
  (#1179). The route establishes ownership with a tenant-scoped fetch and
  then asked the `ConversationServer`, but rendered every `:not_running` it
  got back as `404 "wrong id, or it belongs to another account"` — the
  reported symptom being an owner whose stuck conversation answered `GET`
  with the same key that `interrupt` refused. The miss was conflated at the
  source: one atom meant both "no such conversation row" and "a row in no
  state to interrupt". They are now separate, and the second is `409
  not_running`. `404` stays for a row that is genuinely gone, which the
  delete race still produces. `no_turn_running`, already served for an idle
  conversation and never documented, joins it in the api.md status table.
  The wake-on-miss decision moved to `Conversations.wake_for_interrupt/1`,
  taking the server's pin from 2,835 down to 2,815.

- **A dropped metering event was a free message** (#1143). Comms messages were
  priced from `usage_events`, whose writer `Billing.record_usage/5` rescues and
  logs rather than failing the action that produced it — the right contract for
  a count on a dashboard, and the wrong one for a row the ledger keys on. A
  `comms_*` event that failed to write was a message the customer was never
  charged for, and nothing reconciled it afterwards, because the pricer's
  seven-day look-back only re-reads rows that exist. Messages now have a
  durable row of their own, `comms_messages`, written on the send and receive
  paths through `Team.Comms.record_message/1`, which does **not** rescue: a
  failure is logged as an unbilled message rather than silently discarded. The
  row is keyed on the provider's own message id, so a send retried after a
  timeout that in fact reached the provider bills once, and so a reconciliation
  against a provider invoice has something to join on. `CreditPricer` and the
  `/admin/finance` cost side both read it — leaving one of them on
  `usage_events` would have put a discrepancy inside the view built to find
  discrepancies. `usage_events` keeps the `comms_*` types for the PostHog
  product mirror and no longer prices anything; its docs say so. **Messages
  whose event was dropped before this are not charged retroactively**: there is
  no record of them to price.

- **Platform inference on the gemini runtime was unbilled** (#1459). gemini
  leaves ACP's `PromptResponse.usage` empty and reports the turn's tokens
  under a vendor extension at `_meta.quota.token_count`, so
  `Managoat.ACP.Usage` normalised every gemini turn to nothing:
  `turns.usage` landed NULL, `Workers.CreditPricer` had no tokens to price
  and no `burn_inference` row was written. Worse than a missing debit —
  `PLATFORM_INFERENCE_DAILY_CENTS` is measured from the ledger, so gemini
  spend was outside the daily circuit breaker entirely and a deployment could
  run past its ceiling on gemini alone. Fixed in managoat_acp 0.1.1, taken
  here as a lockfile bump, and recorded as quirk `:gemini_usage_in_meta_quota`
  in managoat_runtimes 0.1.2. **A deployment that ran gemini on a platform key
  will not be charged retroactively**: the pricer looks back seven days but
  prices from `turns.usage`, and those rows are empty for good. The other
  three runtimes were unaffected and are now covered by a test that asserts
  each one's reported shape prices above zero.

- **opencode on a `google/` model could never authenticate** (#1460).
  `managoat_runtimes` exported the Gemini key as `GEMINI_API_KEY`, which is
  what the *gemini* runtime reads. opencode reaches Google through
  `@ai-sdk/google` and reads `GOOGLE_GENERATIVE_AI_API_KEY` only, so the key
  arrived in the sandbox and was ignored, and every turn failed with
  `Authentication required: provider authentication required`. This affected a
  tenant's own Gemini key exactly as much as a platform one, and had been true
  since the runtime was written; the platform keys (#1388) only made it easy to
  hit. Fixed in managoat_runtimes 0.1.1, taken here as a lockfile bump. Nothing
  to change on an agent: the same model and the same credential now work.

### Security

- **hackney 1.25.0 carried four advisories and is on two live request paths**
  (#1468). Bumped to **4.7.4**, which fixes all four:
  [EEF-CVE-2026-47071](https://osv.dev/vulnerability/EEF-CVE-2026-47071)
  (HIGH, a SOCKS5 TLS upgrade that ignored the caller's timeout),
  [EEF-CVE-2026-47076](https://osv.dev/vulnerability/EEF-CVE-2026-47076)
  (an SSRF allowlist bypass through a percent-encoded host),
  [EEF-CVE-2026-47075](https://osv.dev/vulnerability/EEF-CVE-2026-47075)
  (CR/LF injection in a query parameter) and
  [EEF-CVE-2026-47069](https://osv.dev/vulnerability/EEF-CVE-2026-47069)
  (CR/LF injection in the cookie domain and path options). `stripity_stripe`
  was the blocker at 3.2.0, which pins `hackney ~> 1.18`; it moves to 3.3.2,
  which requires `~> 4.0`. Our own constraint was already `~> 3.0`, so only
  the lockfile changed. hackney is reached through **Swoosh** (every
  transactional email, since `Swoosh.ApiClient.Hackney` is the compiled-in
  default and nothing overrides it outside dev and test) and through
  **`Stripe.API`** (every Stripe call, since `:http_module` is unset).
  Sentry is *not* affected — it has defaulted to `Sentry.FinchClient` since
  v12.0.0 — and neither is GitHub OAuth: `oauth2` runs on Tesla, whose
  adapter here is the default `Tesla.Adapter.Httpc`, so hackney is not on
  the token-exchange path at all. Both live paths were exercised against
  4.7.4 rather than accepted on a clean resolve: a real test-mode Stripe read
  and write, and a real message delivered through Resend.

  Carries `grpcbox` 0.17.1 → **0.18.0** (with `ts_chatterbox` 0.15.1 → 0.16.0
  and `gproc` 0.9.1 → 1.2.0), which the hackney bump forces. hackney 4
  delegates HTTP/2 to the `h2` package, whose modules are named `h2_client`,
  `h2_connection`, `h2_frame` and `h2_settings` — the same four names
  `chatterbox` had used since long before, and `chatterbox` is in the tree
  through `grpcbox` under `opentelemetry_exporter`. Two apps cannot ship the
  same module, so `mix release` refused to assemble with `Duplicated modules`
  and **only the prod release build could see it**: the OpenTelemetry
  packages are `only: :prod`, so the whole dev and test suite is green on a
  tree whose release will not build. `ts_chatterbox` 0.16.0 renames its
  modules to `chatterbox_h2_*` and `grpcbox` 0.18.0 is the release that takes
  it. Excluding the gRPC path from the release instead is not available:
  `grpcbox` is a hard dependency of `opentelemetry_exporter`, so Mix rejects
  setting it to `:none` under a `:permanent` parent — even though this
  deployment exports over `otlp_protocol: :http_protobuf` and never calls it.
- **`cowlib` and `gun` advisories remain open, with nothing to upgrade to**
  (#1468). `cowlib 2.19.0` (three advisories) and `gun 2.5.0` (one) are
  already the newest releases on Hex and OSV lists no fixed version for the
  Hex ranges. They arrive only through `sprites` → `gun` → `cowlib`, the
  outbound WebSocket client to one known host, and Fountain serves HTTP with
  **Bandit, not Cowboy**, so cowlib is not on the inbound request path.
  Tracking upstream; `mix hex.audit` reports them and does not fail the build.
- **A sandbox file read could return a fragment of a secret, at a byte offset
  the caller chose** (#1907). `GET /api/sandboxes/:id/file` and
  `GET /api/sandboxes/:id/diff` capped their output in the shell with
  `head -c` and redacted in Elixir over whatever survived the cut. Redaction
  matches a value's own bytes, so a cut through one left a prefix that matched
  nothing and travelled on in the clear. On `/file` the cut lands at
  `max_bytes`, which the caller sends, so this was not an occasional boundary
  artifact that depended on where a value happened to sit: the caller decided
  where the boundary fell relative to a value, and could walk it. Reading the
  sandbox's `.env` that way is exactly what ADR 0039 decision 5 says is
  prevented, and the reader need not be the tenant whose vault values
  redaction protects — a `full`-scope key includes one issued to a
  third-party OAuth app the user authorized. Both endpoints now ask their
  script for enough bytes past the cap that a value lying across it arrives
  whole (one less than the longest known value, which is the widest one can
  straddle it), redact that, and only then cut the result down to what was
  asked for. That last cut is taken in the bytes the script produced rather
  than in the redacted text, because a value replaced by a shorter
  `[REDACTED]` moves every byte behind it forward and could otherwise carry
  an unmatched fragment back inside the cap. `/git-status` was never affected:
  it drops a record its cap bisected rather than returning it. The change to
  what `truncated` reports is under **Changed** above. Present since `/file`
  and `max_bytes` shipped with ADR 0039, and published in SDK 1.15.0.

## [0.16.0] - 2026-09-03

### Upgrade notes

- None.

### Removed

- **`users.onboarding_state`** (#1393, ADR 0038, settling NC-6 from ADR 0007).
  It was the browser wizard's position. The wizard went in #867, after which
  the column only ever held `step_1` or `completed` — which is exactly what
  `onboarding_completed_at` being null or set already says. Gone with it:
  `Accounts.advance_onboarding/2`, the funnel's `by_onboarding_state`
  breakdown and its line on `/admin`, the field on the admin user views, and
  the `onboarding_state` property on `GET /api/auth/me` plus `state` on
  `GET /api/account/onboarding`. **Both onboarding endpoints still work and
  are unchanged otherwise**; `completed` and `completed_at` come from the one
  stamp that is left. The migration's `down/0` restores the column and
  backfills `completed`, but cannot restore which step an unfinished account
  had reached, because nothing has recorded that since #867.

### Added

- **The graduation recipe for umbrella libraries** (#1345, ADR 0037):
  `templates/managoat-library/` (CI, a release gate, a publish workflow that
  makes a version bump on `main` the release, mirroring the SDK's) and
  `scripts/graduate-library.sh`, which moves an `apps/managoat_<name>` app to
  `managoat/managoat_<name>` with its history. CONTRIBUTING.md has the
  recipe, the ordering rule and the cost.
- **A sandbox's files and `git diff` over the API** (ADR 0039). Three
  read-only requests for the apps that watch an agent work:
  `GET /api/sandboxes/:id/files` lists a directory, `/file` returns one
  file's bytes (text or base64, capped by `max_bytes`), and `/diff` returns
  `git diff` with `staged` and `ref`. Full scope only, confined to
  `/home/sprite` and the runtime's workspace, redacted like the transcript,
  and never waking a parked sandbox (`409 sandbox_not_ready`). Built over
  the seam's existing `exec`, so every provider — the self-hosted runner
  included — is covered without an adapter change. There is deliberately
  no exec endpoint; the ADR says why. The SDK gains `sandboxFiles`,
  `sandboxFile` and `sandboxDiff` (1.15.0).

### Changed

- **The Swift SDK becomes a versioned SwiftPM package in `v0.16.0`.** The
  manifest now declares Swift tools 6.1, its SSE iterator passes Swift 6 strict
  concurrency checks, and the release pipeline resolves and builds the tag from
  a clean remote consumer before it creates the GitHub Release.
- **`managoat_runtimes` comes from hex** (#1368, #1345, ADR 0037), the
  ninth library to graduate and the last in the umbrella:
  `apps/managoat_runtimes` is gone, the pin is
  `{:managoat_runtimes, "~> 0.1.0"}`, the source is
  managoat/managoat_runtimes, which publishes to hex from its own CI. The
  umbrella again holds no library app. Nothing about `Managoat.Runtimes`
  changed.
- **Runtime provisioning is a library, `managoat_runtimes`** (#1368, ADR
  0037): how claude, codex, gemini and opencode get into a sandbox and come
  up speaking ACP — the behaviour and dispatcher, the pinned adapter table
  and install, `Layout`, `Instructions`, `Quirks`, the `provider/model_id`
  parser, the skills mechanism, gemini's session-store workaround and the
  `FakeRuntime` — is `apps/managoat_runtimes` as `Managoat.Runtimes`, the
  provisioning half that #1339 left behind when the ACP peer left. The
  behaviour reads the agent as a plain map, not `%Agent{}`. What stays:
  the model suggestion catalog (`Fountain.Agents.ModelCatalog`, new), the
  bundled skill content (`Fountain.SandboxSkills.bundled/0`), the
  permission-ask timeout read (`Fountain.Conversations.Lifecycle.ask_timeout_ms/0`,
  the one thing in there that read Fountain's configuration), `LegacyBlocks`
  and `InferenceCredentials`. Nothing a sandbox receives changed: the same
  files land in the same places with the same env vars, and the
  conversation-server provisioning tests pass unchanged.
- **`managoat_substitution` comes from hex** (#1345, ADR 0037). The first
  library to graduate: `apps/managoat_substitution` is gone,
  `apps/fountain/mix.exs` pins `{:managoat_substitution, "~> 0.1.0"}`, and
  the source is managoat/managoat_substitution, which publishes to hex from
  its own CI. Nothing about `Managoat.Substitution` changed.
- **`managoat_mcp_auth` comes from hex** (#1345, ADR 0037), the second to
  graduate, the same way: `apps/managoat_mcp_auth` is gone, the pin is
  `{:managoat_mcp_auth, "~> 0.1.0"}`, the source is
  managoat/managoat_mcp_auth.
- **`managoat_oauth` comes from hex** (#1345, ADR 0037), the third:
  `apps/managoat_oauth` is gone, the pin is `{:managoat_oauth, "~> 0.1.0"}`,
  the source is managoat/managoat_oauth (its own CI runs the suite against
  a Postgres of its own). `Fountain.OAuth` still `use`s it the same way.
- **`managoat_acp` comes from hex** (#1345, ADR 0037), the fourth:
  `apps/managoat_acp` is gone, the pin is `{:managoat_acp, "~> 0.1.0"}`, the
  source is managoat/managoat_acp. The peer, the permission policy and the
  block normaliser behave as they did; hexdocs.pm/managoat_acp now carries
  the comparison against the other two ACP packages.
- **`managoat_sandbox` comes from hex** (#1345, ADR 0037), the fifth:
  `apps/managoat_sandbox` is gone, the pin is `{:managoat_sandbox, "~> 0.1.0"}`
  in both `apps/fountain` and `apps/managoat_runner` (the one library that
  depends on it, which is what lets runner graduate next), the source is
  managoat/managoat_sandbox with its Sprites client pinned to hex `0.2.0`.
- **`managoat_docs` comes from hex** (#1345, ADR 0037), the sixth:
  `apps/managoat_docs` is gone, the pin is `{:managoat_docs, "~> 0.1.0"}`,
  the source is managoat/managoat_docs. `Fountain.Docs` is still the one
  `use` line, `/docs` and the guardrail tests render and check the manual
  exactly as before.
- **`managoat_broker` comes from hex** (#1345, ADR 0037), the seventh:
  `apps/managoat_broker` is gone, the pin is `{:managoat_broker, "~> 0.1.0"}`,
  the source is managoat/managoat_broker. The native proxy still runs
  beside the Agent Vault client, selected by `BROKER_LISTEN_PORT`.
- **`managoat_runner` comes from hex** (#1345, ADR 0037), the eighth and
  last: `apps/managoat_runner` is gone, the pin is
  `{:managoat_runner, "~> 0.1.0"}`, the source is managoat/managoat_runner.
  The umbrella now holds no library app; every `managoat_*` package is on
  hex from its own repository, and `scripts/test-libraries.sh` and
  `umbrella_layout_test.exs` stay for the next one.

- **The ACP peer, the permission policy and the block normaliser are now
  the `managoat_acp` library** (#1339, ADR 0037). `Fountain.Runtimes.ACP.Peer`
  (the client-side session that outlives the turn), `Protocol`, `Blocks`,
  `Tracer`, `Usage` and `Fountain.Permissions` moved to the Apache-2.0
  `Managoat.ACP` app. The one thing the peer needed from the sandbox was a
  way to write bytes, so the library takes a writer function instead of a
  sandbox command (`Managoat.ACP.Transport`) and depends on nothing but
  `jason` and the OpenTelemetry API; `ConversationServer` passes a writer
  that wraps `Managoat.Sandbox.write_stdin/2` and keeps feeding stdout
  through `Peer.stdout/2`. No protocol behaviour, timer, replay rule or
  report shape changed. The library ships
  `Managoat.ACP.Testing.ScriptedAgent`, an in-BEAM agent, and its own suite
  runs async with no stubs. `Fountain.Runtimes.ACP` (which adapter, how it
  gets into the sandbox, `initialize_params/0`, and now the
  `permission_ask_timeout_seconds` read as `ask_timeout_ms/0`),
  `LegacyBlocks`, `Conversations.Blocks` and the tool bridge stay in
  Fountain. The library README compares the package with `acpex` and
  `agent_client_protocol` and recommends publishing it as it is.

- **The embedded manual, its renderer and its guardrails are now the
  `managoat_docs` library** (#1342, ADR 0037). `Fountain.Docs.Compiler`
  (the `nav.yml` parser and the snippet/admonition/link dialect) and
  `FountainWeb.Markdown` (both render paths: the sanitising one for agent
  output and the trusted one for the manual and `/help`) moved to the
  Apache-2.0 `Managoat.Docs` app, and the structural checks in
  `docs_test.exs` (every page named and present, every link and anchor
  resolving, every compile-time read `COPY`d into the image, every fenced
  language baked) became `Managoat.Docs.GuardrailCase`, a case template any
  Phoenix app with a `/docs` can `use`. `Fountain.Docs` is now one
  `use Managoat.Docs` line naming the root, the nav, the mount, the
  changelog include and the baked-language list; every page renders exactly
  as before. `docs/`, `nav.yml`, `Fountain.Help`, the three prose gates and
  the `/docs` controller stay in Fountain.

- **The OAuth authorization server is now the `managoat_oauth` library**
  (#1343, ADR 0037). The authorization code + PKCE (S256) grant and the
  device grant, their two schemas and a migration for a new consumer moved
  from `Fountain.OAuth` to the Apache-2.0 `Managoat.OAuth` app, as a `use`
  macro the way `Ecto.Repo` is: `Fountain.OAuth` is now an instance of it
  and every controller keeps its call sites. What the library needs from
  the platform is a `Managoat.OAuth.Host` behaviour with three callbacks
  (may this subject hold a token, mint the token, record the audit event);
  `Fountain.OAuth.Host` implements them over `Accounts.create_api_key/3`,
  the suspended-or-unverified check and `Fountain.Audit`, so a token is
  still an API key and the three `oauth.*` audit actions are unchanged.
  The two tables keep their names, their `user_id` column and its foreign
  key; no migration runs. The client registry moved from
  `config :fountain, :oauth_clients` to `config :fountain, Fountain.OAuth,
  clients:`, which `OAUTH_CLIENTS` still populates, so nothing changes for
  an operator. No endpoint, parameter, error code or response shape changed.
- **The native egress credential proxy is the `managoat_broker` library**
  (#1340, ADR 0037, ADR 0019 §8). The proxy PR #1148 built inside the
  server (`CONNECT` and absolute-form forward proxy, the derived root CA
  and per-host leaves, the header injector, the SSRF guard) is ported
  onto `main` as the Apache-2.0 `Managoat.Broker` app, behind a
  `Managoat.Broker.Store` behaviour: a token in, a session of rules with
  the credentials resolved out. `Fountain.Broker` is now a facade over two
  backends, `Fountain.Broker.AgentVault` (the vendor client, moved
  unchanged) and `Fountain.Broker.Native` (the library, with a
  `broker_sessions` table as its store); every public function keeps its
  name and arity, so the 24 call sites are untouched.

- **The self-hosted runner protocol is now the `managoat_runner` library**
  (#1341, ADR 0037). The `WebSock` connection process, the sandbox adapter
  that speaks to a runner daemon over it, the `runner-<32 hex>-<8 hex>` name
  shape and the in-BEAM `FakeDaemon` moved from `Fountain.Runners.Connection`
  and `Fountain.Sandbox.Runner` to the Apache-2.0 `Managoat.Runner` app. What
  the library needs from the platform is a `Managoat.Runner.Host` behaviour
  (register, unregister, whereis, online, heartbeat, presence);
  `Fountain.Runners.Host` implements it over the Horde registry, the
  `last_seen_at` stamp and the presence broadcast, and the library ships
  `Managoat.Runner.Host.Local` over a plain `Registry` for a consumer without
  a cluster. The wire protocol, the error taxonomy and every frame shape are
  unchanged, so the Go daemon is untouched. Fountain still owns the `runners`
  table, placement, presence and the socket's authentication.

- **MCP authorization discovery is now the `managoat_mcp_auth` library**
  (#1338, ADR 0037). The RFC 9728 / 8414 / 7591 discovery chain and its SSRF
  URL guard moved from `Fountain.Connections` to the Apache-2.0
  `Managoat.McpAuth` app. Fountain still owns its provider rows, OAuth client,
  Gmail tool server and verified server catalog; the extraction changes the
  package boundary without changing discovery behaviour.

- **The sandbox seam is a library, `managoat_sandbox`** (#1337, ADR 0037).
  `Fountain.Sandbox` (the behaviour, the facade and the error taxonomy), the
  Sprites, E2B and Daytona adapters, `Fountain.Retry`, the in-memory Fake
  and the conformance suite are now `Managoat.Sandbox.*` in
  `apps/managoat_sandbox`, Apache-2.0, with no change in behaviour. The
  adapters read their settings from the library's own otp_app
  (`config :managoat_sandbox, Managoat.Sandbox.Sprites, ...`), populated by
  `config/runtime.exs` from the same environment variables as before, so
  nothing changes for an operator. The self-hosted runner adapter stays in
  Fountain and implements the behaviour from outside the library, and the
  "which providers are usable on this deployment" policy is now
  `Fountain.SandboxProviders`. The Fake and the conformance case ship in the
  library's `lib/` so a consumer can run the suite against an adapter of its
  own.

- **The first component library, `managoat_substitution`** (#1336, ADR
  0037). Fountain's database-free subsystems are being extracted as
  Apache-2.0 libraries under the `Managoat.*` namespace, first as apps in
  this umbrella and later as `managoat/<name>` repositories (#1334). The
  `${VAR}` substitution engine is the first: `Fountain.Substitution` is now
  `Managoat.Substitution` in `apps/managoat_substitution`, with no change in
  behaviour. Nothing user-facing moves; the umbrella gains the mechanics
  every later extraction reuses (a library test step in CI with its coverage
  merged into the gate, a Dockerfile `COPY` per library, and a test that
  refuses a library which reaches back into Fountain).

- **`ConversationServer` only shrinks** (#1370, tracker #1369). The first
  step of refactoring the server by subtraction, the "not a rewrite" ADR
  0037 promised: `conversation_server_size_test.exs` pins the file at its
  current 4,498 lines and fails if it grows, and each later sub-issue lowers
  the pin in the PR that moves a function family out. The section headers
  now say what sits under them (`sprite environment and egress`, `turns`,
  `permissions, reclaim and redaction`). No code moved.
- **The MCP server list and the callback key have left `ConversationServer`**
  (#1371, tracker #1369). `Fountain.Conversations.McpServers` assembles the
  list a runtime receives (the agent's own after `${VAR}` substitution, then
  the Fountain-served buzz, team, team-comms and caller-tool entries) and
  `Fountain.Conversations.CallbackKey` mints, rotates and expires the
  sprite's callback key and builds its env pair. Functions over rows and
  values; the server passes in what it holds. No behaviour, timer, audit
  event or option changed, and `ConversationServer.callback_api_key_opts/0`
  still answers for the tests that pin it. The pin drops from 4,498 to
  4,348.
- **Sprite environment assembly and the runtime file writes have left
  `ConversationServer`** (#1372, tracker #1369). `Fountain.Conversations.SpriteEnv`
  turns rows and decrypted secrets into the sandbox's ordered env list, with
  the one precedence rule (a vault wins over an environment) stated there
  and the list registered for redaction before it is returned.
  `Fountain.Conversations.Provisioning` gains the steps the server carried
  itself: creating the sandbox, recording its URL, the setup script, the
  runtime config, the instructions file and the runtime's own preparation.
  Sixteen functions, same bodies, no behaviour change; the brokered
  placeholders reach the env through one argument, which is the seam the
  egress move (#1373) uses next. The pin drops from 4,348 to 4,168.
- **Egress brokerage and the connection secrets have left
  `ConversationServer`** (#1373, tracker #1369). `Fountain.Conversations.Egress`
  holds everything ADR 0019 wired into a conversation: the split rules
  (bindings, connection tokens, catalog keys, inference credentials), the
  proxy session's mint, re-prepare and release, the CA install and the
  network floor. It calls the `Fountain.Broker` facade and
  `Fountain.Connections`; the server keeps the session and its placeholders
  in state and three short wrappers that apply what comes back. Seventeen
  functions, same bodies, no behaviour, stage or log change. The Agent Vault
  client's deletion now touches one file beside the facade. The pin drops
  from 4,168 to 3,991.
- **The turn is a state machine** (#1374, tracker #1369).
  `Fountain.Conversations.TurnMachine` (the sub-issue's `Turn` is the
  schema's name) holds the running turn, its span, its metrics and its
  tracer as one value; `handle/3` takes a peer report and returns the next
  value with a list of effects (persist these lines, open an autonomous
  turn, re-arm the quiet timer, persist the session id, hold a permission
  request, finish the turn, drop the connection), which `ConversationServer`
  applies in order. Ending a turn, the interrupt, and everything a fresh
  turn decides before the spawn (the row, the session plan, the argv, the
  span, the failure before start) are its functions; the server keeps the
  spawn, the peer and the connection. Twenty-four functions and twelve
  report handlers moved; no stage, log line, telemetry event, timer or
  audit event changed. The pin drops from 3,991 to 3,322.
- **What a turn waits on has left `ConversationServer`** (#1375, tracker
  #1369). `Fountain.Conversations.Pending` is the parked caller-tool calls
  with their deadlines and the permission request's timeout, as one value,
  with the functions that add, answer, deny, expire and drain it and return
  the reply, the turn row and the next value. The server's five
  `handle_call` clauses, the two timeout handlers and the ask are each a
  call into it; the GenServer messages, the stage events and the audit of a
  denial are unchanged, and `Fountain.CallerTools` still owns the wire
  shapes. The pin drops from 3,322 to 3,192.
- **The sandbox reclaim actions have joined the policy that decides them**
  (#1376, tracker #1369). `Fountain.Conversations.Lifecycle` already held
  the bounds (`check/4`, `idle_action/1`, `explain/1,2`); it now also holds
  the consequence — the sandbox clock, the lifecycle tick, the two verdicts
  with their suspend call, the park, the destroy and the cast that tells the
  co-tenants on the machine. A reader of `idle_action/1` can see what
  `:destroy` costs without opening another file. The server keeps the log
  line, the connection drop and the `{:stop, :normal, …}` around each. No
  stage, log line, telemetry event, timer or audit event changed. The pin
  drops from 3,192 to 3,049.

### Added

- **A native egress credential broker, selected by `BROKER_LISTEN_PORT`**
  (#1340, ADR 0019). Fountain can now run the egress proxy itself instead of
  an Agent Vault instance: set `BROKER_LISTEN_PORT` (and `BROKER_PROXY_URL`,
  the address a sandbox dials) and every replica listens, mints a session
  per conversation into the new `broker_sessions` table (token hashed,
  rules encrypted under the tenant key) and attaches credentials at the
  proxy. `BROKER_URL` still selects Agent Vault; setting both is a boot
  error. Every other `BROKER_*` variable keeps its meaning. On the native
  backend the request log is one log line per request and
  `GET /api/conversations/:id/egress` returns an empty page; a stored log
  is still owed. Merging this changes nothing on a deployment that sets
  `BROKER_URL`; the flip is a deployment change.

- **A verified registry of remote MCP servers** (#1322). Fountain now ships
  a list of ten remote MCP servers (Linear, Sentry, Notion, Asana,
  Cloudflare, PayPal, Square, Webflow, Stripe, GitHub) whose MCP
  authorization chain is verified to complete, each entry carrying the date
  it was last checked. The list feeds preset chips on the console's
  *Connect a remote MCP server* box, an `mcp_servers` key on
  `GET /api/catalog`, and per-server pages under the docs catalog.
  `scripts/mcp-catalog-probe.exs` re-verifies every entry through the
  production discovery code, on demand and on a monthly schedule; a failed
  probe means the entry keeps its stale date, so the claim stays honest.
  Suggestions, not an allowlist: any URL still discovers.

### Fixed

- **Releases are cut through a pull request.** The release bump used to
  commit straight to `main`, which the branch ruleset rejects, so the two
  v0.15.0 attempts failed before the tag step (#1329). "Release bump" now
  opens a `release/vX.Y.Z` PR; merging it tags the squash commit and starts
  the release. The "Compose boots the pinned image" check skips on that PR
  and on the merged commit, where the pinned image cannot exist yet, and
  runs on the tag after the image is published instead. That red check on
  `main` is also why the deployed footer stayed on v0.14.0 after 0.15.0
  merged: the failed CI run kept the image from being built.
- **The quickstart installs on Linux.** The page offered only `brew install`,
  and Homebrew on Linux refuses to install any formula, even one that only
  downloads a prebuilt binary, until a C compiler is present. Walked on a
  fresh Ubuntu 24.04 host, the first command failed with "No developer tools
  installed". The page now gives the release binary for Linux and names the
  compiler requirement for anyone who prefers Homebrew there.

## [0.15.0] — 2026-09-01

### Upgrade notes

- **Three migrations, all additive.** `connection_providers` (#1187),
  `conversations.caller_tools` (#1203) and `oauth_device_grants` (#1309). No
  column is dropped, so a rolling deploy across this boundary is seamless.
- **The CLI's `auth login` changed its default.** On a terminal it runs the
  browser (device) flow; email + password remains when stdin is a pipe or
  with `--password`, and `--api-key` takes a pasted key. A device login needs
  the server at 0.15.0 (`POST /api/auth/device`); against an older server the
  CLI says so and `--password` or `--api-key` still work. An older CLI
  against a 0.15.0 server keeps working with email + password.
- **The default app URLs moved.** Unset `CONVERSATIONS_APP_URL` and
  `TEAM_APP_URL` now resolve to
  `https://fountain-conversations.demo.managoat.com/` and
  `https://fountain-team.demo.managoat.com/`; the `jakegaylor.com` builds
  are retired. A self-host that relied on the defaults must add the new
  origin to `API_CORS_ORIGINS` and, if it registered the hosted app in
  `OAUTH_CLIENTS`, update the redirect URI. Operators pointing the variables
  at their own builds are unaffected.
- **Compose users: take the new `docker-compose.yml`.** It forwards eighteen
  variables the old one silently dropped (see Fixed). `SECRET_KEY_BASE` and
  `MASTER_SECRETS_KEY` are commented out in `.env.compose.example`; keep the
  values you appended.
- **New env vars, all optional and inert when unset.** `BRAND_ASSETS_URL`
  (a directory of seven brand files on any static host; must be an absolute
  http(s) URL or boot raises), `MICROSOFT_OAUTH_CLIENT_ID` / `_SECRET` and
  `SLACK_OAUTH_CLIENT_ID` / `_SECRET` (platform connection providers, the
  same shape as Google), and `GOOGLE_OAUTH_SCOPES`, `MICROSOFT_OAUTH_SCOPES`,
  `SLACK_OAUTH_USER_SCOPES` (scope overrides). The Google provider now also
  asks for the Calendar scope; an existing connection keeps its grants and
  picks it up on reconnect.
- **`PUBLIC_URL` gains two fallbacks**, `RENDER_EXTERNAL_URL` and
  `https://$FLY_APP_NAME.fly.dev`. Your own `PUBLIC_URL` still wins, and a
  blank one no longer shadows the fallbacks.
- **The OpenAI-compatible endpoints are off unless flagged.**
  `/v1/chat/completions` and `/v1/models` answer 404
  `openai_compat_not_enabled` until `FEATURE_FLAGS_ON=openai_compat`.
- **The Firecracker runner backend is opt-in** (`fountain runner --backend
  firecracker`; Linux, `/dev/kvm`, `CAP_NET_ADMIN`). `--backend process` is
  unchanged. A tenant in `BROKER_TENANTS` cannot launch on any runner.
- **TypeScript SDK 1.8.0 to 1.13.0.** One breaking change:
  `client.connections.providers()` became `client.connections.providers.list()`
  and returns full `ConnectionProvider` rows (1.13.0).
- No route was removed; every router change in the range is an addition.

### Added

- **The CLI signs in through the browser, and takes a pasted key**
  (#1305, #1307, #1309, #1310). `fountain auth login` on a terminal now runs
  an RFC 8628 device flow: the CLI prints a short `XXXX-XXXX` code and the
  console URL, opens it where it can, and polls until the account approves
  the device on the console's new `/device` page. The key it saves is a
  full-scope API key in the same shape `POST /api/auth/token` returns. It
  works for every account, which is the point: an account created with *Sign
  up with GitHub* has no password, and the email + password exchange died
  with a bare 401 for it. `--device` forces the flow, `--password` forces the
  email + password prompt (piped stdin still reads a password, so scripts are
  unchanged), and `--api-key` prompts for a key created on the console's API
  keys page, verifies it against `GET /api/auth/me` and saves it. A password
  401 on a terminal offers the browser flow. Server side: `POST
  /api/auth/device` (public, rate-limited) and `POST /api/auth/device/token`
  with the RFC 8628 error vocabulary, `oauth_device_grants` holding a hashed
  device code with a fifteen-minute expiry and single use, pruned by
  `OAuth.prune_expired`; approval and denial audit as `oauth.device_approved`
  and `oauth.device_denied`. In the OpenAPI spec and SDK 1.12.0's generated
  types. The 401 stays uniform on purpose (#324): the server never says which
  auth method an account has.

- **A first-agent quickstart at `/docs/quickstart`** (#1304). Choose the
  hosted server or a `docker compose up`, put an inference key under Account,
  then Inference keys, `fountain apply` the manifest in
  `examples/quickstart/fountain.yml`, and run one turn against Fountain's own
  public repository. `docs/index.md` and the README point here first.

- **Two more unlisted campaign pages, `/oss-launch` and `/buzz-launch`**
  (#1302, #1303, #1306, #1308, #1311, #1312, #1313, #1314, #1315, #1316,
  #1318). `/oss-launch` makes the open-source engine's argument from the
  engineer's chair outward: the deployment paths (compose, Render, Fly,
  Kubernetes, Coolify), the manifest and first SDK run, a system map of
  protocols in, runtimes, sandboxes and credential-bound systems, and what
  telemetry stays on the instance. `/buzz-launch` sells hosted Buzz agents
  from one fact, that the agent's body should outlive the laptop, and every
  claim on it is the marketing register of a sentence in
  `docs/integrations/buzz.md`. Both are unlisted like `/launch`; off the
  marketing site they redirect to `/docs/open-source` and
  `/docs/integrations/buzz`.

- **Open Graph and Twitter cards on every page** (#1193). A link to the
  landing page, a docs page or the sign-in page unfurls with a title, a
  description and a 1200-by-630 card. `FountainWeb.OpenGraph` builds `og:url`
  and `og:image` from `PUBLIC_URL`, not the request host, and the card
  carries no product name, so a `PRODUCT_NAME` deployment reuses it. On an
  instance that is not the marketing site the description states what the
  page is and carries none of the pitch.

- **Bring your own OAuth provider, and connect a remote MCP server by URL**
  (#1186, ADR 0033). Connections were Google-only with Fountain's own OAuth
  client; now Google is the one *platform* provider and every other service
  is a provider the tenant defines on *Account → Connections*:
  - **`oauth2`**: register an app at the service (GitHub, Slack, Notion,
    Linear… presets fill the endpoints), paste the redirect URI the console
    shows (`/connections/<provider id>/callback`) and the client id and
    secret. Scopes, PKCE, the client-auth method, the env var the token is
    brokered under (`GITHUB_ACCESS_TOKEN` from the slug) and the hosts the
    broker attaches it to are all yours to set.
  - **`mcp`**: paste a remote MCP server's URL and nothing else. Fountain
    follows the MCP authorization spec — `401` → RFC 9728 protected-resource
    metadata → RFC 8414 authorization-server metadata — runs a PKCE code
    flow with the RFC 8707 `resource` parameter, and registers a client by
    RFC 7591 dynamic registration where the server offers it (reused for a
    second server behind the same authorization server). No client id is
    typed anywhere; a server without registration takes a pasted one.
  - An agent attaches a remote server with a connection —
    `{"linear": {"type": "http", "url": "https://mcp.linear.app/mcp", "connection": "<id>"}}` —
    and the sandbox calls it with a placeholder bearer the egress broker
    swaps for the real token on that host only. A stdio server that reads
    the env var needs nothing new. The agent form's *Connected account*
    server type gained the optional URL.
  - Refresh follows the provider: rotating refresh tokens are stored, no
    `expires_in` means non-expiring, and a provider that issues no refresh
    token leaves the connection **`expired`** (a new status) when the token
    lapses, with a *Reconnect* button. Revoke is RFC 7009 where the
    provider has a revoke URL.
  - Every tenant-supplied URL is https-only and may not resolve into the
    cluster (`Managoat.McpAuth.UrlGuard`), at save time and at every
    fetch, including the URLs discovery gets back from the server.
  - API: `GET/POST /api/connection-providers`,
    `GET/PATCH/DELETE /api/connection-providers/:id`,
    `POST /api/connection-providers/:id/discover`; connections carry
    `provider_id`. SDK 1.13.0: `client.connections.providers` (list, get,
    create, update, delete, discover); `connections.providers()` the method
    became `connections.providers.list()`.
  - Audit: `connection_provider.created` / `.updated` / `.deleted`,
    `connection.expired`. Never a client secret or a token.
  - Docs: *Connect a service with your own OAuth app*, *Connect a remote MCP
    server*, and a catalog page per platform provider. ADR 0019 gains the
    rotating-secret contract and the per-conversation vault that #1178 owed.
  Only for accounts the egress broker is on for, as before.

- **Two more platform connection providers: Microsoft and Slack** (#1299).
  The Connections page and `GET /api/connections/providers` now list three
  platform providers. One Microsoft sign-in covers Outlook mail, calendar and
  Teams chat, brokered to `graph.microsoft.com` under
  `MICROSOFT_ACCESS_TOKEN`; a Slack connection holds a user token per
  workspace, brokered to `slack.com` under `SLACK_ACCESS_TOKEN`. Each is
  configured by its own `<SLUG>_OAUTH_CLIENT_ID` / `_SECRET` pair and listed
  as not configured until the operator sets them. The Google provider now
  also requests the Calendar scope, so one Google sign-in covers Gmail and
  Calendar; `include_granted_scopes` was already sent, so an existing
  connection keeps its grants and reconnecting adds the new scope. Operators
  can override any platform provider's scope list
  (`GOOGLE_OAUTH_SCOPES`, `MICROSOFT_OAUTH_SCOPES`,
  `SLACK_OAUTH_USER_SCOPES`) — the lever for app-verification coverage.
  The Fountain-served Gmail tools now refuse a connection from another
  provider with a readable error; a Microsoft or Slack connection attaches
  to a remote MCP server by URL, or to a stdio server through its brokered
  env key. ADR 0033 records why these three clear the platform bar.

- **A focused launch page at `/launch`.** The homepage remains the canonical
  product page; this unlisted campaign page makes the shorter argument for a
  developer arriving from a launch announcement. It leads with ready machines
  and the work-only meter, then uses the production case-study figures and the
  tour's 43-second first turn and 13-second revision as its proof. The rest of
  the page names the responsibility split, both sandbox modes, the exact
  redaction boundary and the product's current limitations before asking the
  reader to run a first agent. Prices, opening credit, concurrency settings and
  case-study figures come from the same helpers as the homepage, so the page
  cannot preserve an old plan or an old number. On an instance that is not the
  marketing site, `/launch` redirects to the executable tour.

- **One page for the questions, at `/faq`.** Three marketing pages carried a
  question-shaped block at the bottom, and a reader with a question had to
  guess which page it sat on. They are one page now, grouped into building on
  it, what it costs, security and data, and running it yourself, linked from
  the footer. The homepage keeps its six-question grid, which is the problem
  statement rather than an FAQ, and its two other blocks moved whole: the
  security answers (`security_answers/0`, with every limit still stated beside
  the answer it limits, and the "what we do not have" list still with them)
  and the objections, now `build_faq/0`. The questions on `/self-hosted` moved the
  same way, still `self_host_faq/0`. Both pages link back to their section by
  anchor rather than repeating the copy, and the suite asserts those anchors
  exist. On a deployment that bills, a billing section reads the same price
  card the ledger burns at, so the page cannot quote a rate the meter does not
  charge. Off the marketing site `/faq` redirects into the manual, like the
  other sales pages.

- **A Fly blueprint, and a name for the hosts that do not work.** `fly.toml`
  declares one machine on the published image, defaulted the way compose and
  `render.yaml` are, and the guide at `/docs/guides/operate/fly` attaches a
  managed Postgres in a second command. What the file mostly does is hold off
  two Fly defaults that are right for a web app and wrong for this one:
  `auto_stop_machines` parks an idle machine, and every scheduler runs inside
  the app process, so a parked instance quietly stops reaping sandboxes and
  stops pricing turns; `canary` and `bluegreen` bring a second machine up
  before retiring the first, and two machines are two schedulers racing over
  the same sandboxes. `auto_stop_machines`, `auto_start_machines`,
  `min_machines_running` and `strategy = "rolling"` are each pinned by a guard
  test for that reason. `PUBLIC_URL` is absent here too, for a different
  reason than on Render: the hostname is knowable, but the file ships with an
  app name `fly launch` replaces, so `config/runtime.exs` derives
  `https://$FLY_APP_NAME.fly.dev` behind an operator's own `PUBLIC_URL`.
  `FLY_APP_NAME` was already read for an OTel attribute and sat on
  `config_reference_test`'s exemption list; it builds an operator-visible URL
  now, so it has a row in the configuration reference and that exemption list
  is empty and gone.

- **Coolify and Dokploy, on the compose file that already exists.** No new
  file. `/docs/guides/operate/coolify` names the five values to set in the
  interface and the two compose defaults a public server must not keep, which
  are the published Postgres port with its default password and a `PUBLIC_URL`
  that stays at `http://localhost:4000` and quietly puts localhost in every
  verification email.

- **What a host must give you, and which popular ones do not.**
  `/docs/self-hosting` now states the three properties a host needs (one
  instance and only one, a process that never parks, long-lived connections)
  and names Cloud Run, App Runner, Lambda, Vercel, Netlify and Cloudflare
  Workers as hosts that fail one of them. They fail quietly: an instance that
  scales to zero looks healthy while it stops reaping sandboxes and pricing
  turns. The README says the same thing in three lines, and now points at
  `render.yaml` and `fly.toml`, which it never mentioned.

- **A Render blueprint, for an instance that is not ours.** `render.yaml`
  declares one web service on the published image and one managed Postgres,
  so somebody who wants Fountain on Render applies a blueprint instead of
  reverse-engineering the compose file. It asks for three values
  (`SECRET_KEY_BASE`, `MASTER_SECRETS_KEY`, `SPRITES_TOKEN`) and defaults the
  rest the way compose does: credits off, no mail, registration open for the
  first account, one instance. `PUBLIC_URL` is deliberately not among the
  three. It is required in prod and the hostname does not exist until the
  first deploy has happened, so a blueprint that asked for it up front could
  never complete its own first deploy; `config/runtime.exs` now falls back to
  Render's injected `RENDER_EXTERNAL_URL`, behind an operator's own
  `PUBLIC_URL`. That fallback is a list rather than an `||` chain, because
  `""` is truthy in Elixir and a blank `PUBLIC_URL` — what every `${VAR:-}`
  and every blank dashboard field delivers — would otherwise win it and raise.
  Three guards hold the new surface to the old one: every key the blueprint
  sets must be a variable the app reads, every variable a prod boot raises
  without must be present, and the image pin joins the four `release-bump.yml`
  already moves. The guide is at `/docs/guides/operate/render`.

- **A code review bot, whole, at `/code-review-bot`.** The shortest useful
  program anybody writes on this API, shown unabridged rather than described:
  a GitHub webhook handler that upserts the reviewer for the repository it
  just heard from and hires it. Two snippets, one 36 lines and one 39, and
  the argument the page makes is the absent half. No runner pool, no queue,
  no container image per repository and no per-pull-request state, because
  an Environment carries the checkout, a Vault carries the credential and a
  channel id carries the pull request. Both lengths are counted off the
  snippets rather than typed, and the controller test pins every annotated
  line to a line of the file above it. Like the other pitch pages, an
  instance that is not the marketing site is sent to the manual's tour.
  The page is **unlisted**: it answers at its URL and nothing on the site
  links to it, because the handler it shows has never been run against a live
  webhook.

- **A self-hosted runner can put each sandbox in its own Firecracker microVM.**
  `fountain runner --backend firecracker` replaces the sandbox directory with
  a microVM booted from a private copy of a base image, on a tap device
  attached to a bridge you name. ADR 0022 shipped the runner in trusted mode
  and recorded the VM mode as compatible with the protocol and unbuilt; this
  builds it. The in-VM agent, `fountain runner-guest`, serves the same
  protocol with the same backend a trusted-mode runner uses, so exec, streams,
  stdin, sessions and replay are not reimplemented for microVMs and the
  isolation is the machine boundary rather than a second code path. An idle
  sandbox parks by pausing its microVM, which keeps the guest's processes
  rather than stopping them. `--backend process` stays the default and is
  unchanged. Needs Linux, `/dev/kvm` and `CAP_NET_ADMIN`; the base image is
  yours to build, and the runners guide has the recipe. Egress policy is
  still not advertised on runners, because capabilities belong to the adapter
  rather than to one runner, and for a tenant in `BROKER_TENANTS` that is a
  blocker rather than a downgrade: no runner, process or microVM, can host
  the conversation, and the launch fails with `backend_lacks_network_policy`
  before a sandbox exists (#1226). See ADR 0036.

- **Search over the manual, at `/docs` (#1009).** A field at the top of the
  sidebar filters every page title and every heading as you type, with arrow
  keys and Enter to jump. The index is the manual's structure, not its prose,
  and is built at compile time, so there is no search service, no request and
  no asset pipeline behind it. Since #1008 `/docs` is the only place the
  manual is published, which left it as the one copy with no way to search.

- **A case study, `/case-studies/self-healing-infrastructure`.** A Kubernetes
  estate that answers its own alerts. Prometheus fires, a webhook opens a
  Fountain conversation, and the agent reads the cluster through a read-only
  API, names the commit that broke it, and opens one minimal pull request. It
  cannot merge that pull request, and the page is mostly about why: the
  identity it pushes as is one GitHub refuses to let approve its own work. The
  numbers are counted from one production estate over a stated window, 78
  incidents in fifteen days, and the page quotes the agent's own root-cause
  paragraph rather than a summary of it. Like `/integrations`, `/built-with`
  and `/self-hosted`, it is sales copy, so an instance that is not the
  marketing site redirects into the manual.

- **A landing page for running it yourself, `/self-hosted`.** The case for
  an instance of your own, next to the case for ours: the bring-up in five
  commands, the three licences and what each one asks of you, four rungs of
  ownership down to the case where no third-party account is left in the loop,
  and the four costs that land on the operator instead. The middle of it is
  the inversion worth a page: the three features the hosted platform rations
  are an env var on an instance of your own. Like `/integrations` and
  `/built-with`, it is sales copy, so an instance that is not the marketing
  site redirects to the manual's own `Self-host Fountain`.

- **A gallery of the applications built on the API, `/built-with`.**
  Twelve products, grouped by who they are for: a researcher that returns
  cited briefs, an analyst that runs Python on a CSV, repository question-answering with file-and-line citations, a fleet
  coordinator, a shared dev workbench, a DNS desk behind an approval gate, an
  SRE on a cron, two config-audit products, a blind model bake-off, and the
  team and conversation clients. Each card carries a live link and a source
  link, and the suite checks that every entry names an absolute URL and a
  repository, so no card can sell something nobody can open. The homepage
  carries a band naming them all. Off the marketing site the page redirects
  to the manual's build guide.

- **An integrations page on the marketing site, `/integrations`.** The
  protocols Fountain answers (AG-UI, the Agent Client Protocol, OpenAI chat
  completions, MCP, its own REST API and webhooks, and Buzz over Nostr), what
  already speaks each one, a snippet for each shape of builder, and the
  runtimes, models, sandboxes and brokered services behind the door. Data
  first: every link into the manual is checked by the suite, and the broker
  presets are read from the same catalog the console offers. Off the marketing
  site it redirects to the manual's own list, as `/` serves a plain front
  door there.

- **Tool bridge on `/v1/chat/completions` and AG-UI (#1202).** A request's
  `tools` are offered to the agent beside its own, through one more
  Fountain-served MCP server (`POST /api/mcp/caller/:conversation_id`). When
  the agent calls one, the completion ends with `finish_reason: "tool_calls"`
  (AG-UI: `TOOL_CALL_*` then `RUN_FINISHED` with `stopReason: "tool_calls"`)
  while the turn stays open; the next request's `role: "tool"` messages
  answer it and the turn resumes. A `user` message while calls are pending
  is 409 `tool_calls_pending`; an unanswered call expires on the permission
  deadline. The sandbox's own tools still never come back as tool calls.
  ADR 0035 decision 4 amended. `examples/deepagents-contractor` gains
  `FountainAgent.as_model()` for `create_agent`.

- **LangChain and Deep Agents example.** `examples/deepagents-contractor`:
  a Deep Agent orchestrator whose subagents are Fountain agents, over the
  OpenAI-compatible API. `fountain_langchain.py` makes one agent a
  `CompiledSubAgent`, a LangChain tool or a bare runnable, keyed to the
  LangGraph `thread_id` so one thread keeps one sandbox per agent. Docs page
  `docs/integrations/langchain.md`.

- **OpenAI-compatible chat completions (alpha, flag `openai_compat`).**
  `POST /v1/chat/completions` and
  `GET /v1/models`, where the `model` is one of the tenant's agents (by name
  or id), so any gateway (LiteLLM, Portkey, Kong, Cloudflare AI Gateway) or
  base-URL chat client (Open WebUI, LibreChat, the `openai` SDK, `curl`)
  drives a Fountain agent with no plugin. The thread is the conversation:
  `X-Fountain-Thread`, else the request's `user` field, binds to channel
  `openai:<key>`; only the newest user message is sent as the prompt, the
  system prompt rides along with the first one, and a request with neither
  key is a 400. `stream: true` streams `chat.completion.chunk` deltas
  (`content` for the reply, `reasoning_content` for thinking, tool use and
  provisioning stages) ending with `[DONE]`; `stream: false` blocks for the
  turn. Tool calls are never emitted, `usage` is zeros, a busy thread is 409
  with `Retry-After`. ADR 0035; `docs/integrations/openai-compatible.md`.
  Off by default on the hosted platform: 404 `openai_compat_not_enabled`
  until the flag is on (`FEATURE_FLAGS_ON=openai_compat` self-hosted). A
  runnable client on the stock `openai` package is in `examples/openai-chat`.
  The TypeScript SDK's generated types follow. #1198

- **Agent config versions over the API.** `GET /api/agents/:id/versions`
  lists an agent's config history newest first and
  `GET /api/agents/:id/versions/:version` returns one version with its full
  config; both are read-only (rollback stays a console action). Every
  conversation now reports the version it launched under as
  `agent_version_id` plus the resolved `agent_version` number (null for
  conversations that predate versioning; the number is resolved on the
  conversation list and get endpoints). The account export fetches version
  history in one query instead of one per agent. The TypeScript SDK's
  generated types follow (SDK 1.9.0). #1051

- **`BRAND_ASSETS_URL`.** A deployment can serve its own app icon, favicons
  and Open Graph card from any static host instead of the files in the
  release image: point the variable at a directory holding the seven files
  `Fountain.Brand.assets/0` names and the chrome links them, the card
  unfurls with them and the CSP admits the origin on `img-src`. Unset,
  nothing changes. Changing a brand's pixels no longer means rebuilding the
  engine.

### Changed

- **The marketing site is set on paper** (#1258, #1260). Every page the
  marketing controller serves renders under `data-skin="paper"`: hairline
  rules, no corners, no shadows, a serif for headings, old-style figures for
  measured numbers, and one royal-purple accent that is also the brand.
  `?skin=classic` is the way back while the look is being decided. The manual
  and the console keep the console's tokens. A `BRAND_ASSETS_URL` bundle
  gains a seventh file, `mark-mono.png`, a one-colour mark on a transparent
  ground that the paper chrome uses.

- **The demo suite lives at `*.demo.managoat.com`, and Reflex leaves
  `/built-with`** (#1247, #1248). Every app on `/built-with` moved into the
  managoat org and from `*.inevitable.fyi` and GitHub Pages to
  `<repo>.demo.managoat.com`. `Fountain.Apps`'s defaults for
  `CONVERSATIONS_APP_URL` and `TEAM_APP_URL` follow
  (`https://fountain-conversations.demo.managoat.com/`,
  `https://fountain-team.demo.managoat.com/`), as do the hermes plugin and
  SDK 1.11.1's `DEFAULT_APP_URL`. Reflex is its own product rather than a
  demo, so the gallery counts twelve. See the upgrade notes if your instance
  relied on the old defaults.

- **Docs headings** (#1239). The catalog and integration pages' `## At a
  glance` is `## Summary` (the `#at-a-glance` anchor is gone), and *Wire up
  observability* is *Configure observability* at the same slug.

- **The Open Graph card carries the current product promise.** Link previews
  now lead with ready machines and their wake-work-park lifecycle instead of
  the retired "Have the conversation" headline. The 1200-by-630 card uses the
  marketing site's paper and violet system, its alt text says the same thing
  the image does, and the checked-in SVG and render script make the bitmap
  reproducible.

- **The integrations page leads with the managed machine and the work-only
  meter.** Its hero now treats editors, chat apps, gateways, frameworks and
  code as ways into Fountain rather than the product itself. The machine is
  provisioned, preserves its work and parks between turns, so the reader sees
  the two differences in the first screen: there is no machine to manage and
  no idle time to pay for. Registration and integration-guide actions now sit
  beside that promise instead of appearing only at the bottom of the page.

- **The homepage case study distinguishes investigation from resolution.** The
  pager still reaches an on-call engineer while an agent investigates in
  parallel, and the copy now says that a pull request follows only when the
  agent finds a repository fix. Its headline, stat labels and incident link
  make that human gate and the scope of the measured proof explicit.

- **The homepage makes session state and the two scaling modes explicit.** A
  caller binds a conversation to an id it already owns and sends the same
  Agent, Environment and Vault to resume it, without keeping a lookup table of
  Fountain conversation ids. The copy now limits the destroy-with-the-
  conversation memory boundary to the default ephemeral mode. The Scale cards
  name the choice it leads into: give each job its own sandbox, or use
  persistent mode to share one checkout across conversations.

- **The homepage protocols section starts with the integration outcome.** It
  now tells builders to put Fountain behind the stack they already use instead
  of leading with the REST API's internal layering. Each protocol description
  says what it connects, and the integrations link says what the reader will
  find there.

- **The homepage sells the reader an outcome, and shows the manifest.** Every
  section heading and every claim on `/` now says what the reader gets rather
  than what Fountain does. The six claims that were questions ("How does the
  work get out?") are statements of value ("Nothing to build to get the work
  out"), rendered as a definition list like the rest of the page rather than
  as the only bordered cards on it. The hero subheadline drops the two
  sentences the headline already made and gives the meter a sentence of its
  own, and the Open Graph description follows it. `build_steps/0` holds a new
  `fountain apply` manifest beside the SDK call, one document per beat, so the
  section that promises three templates and one call shows all four; the suite
  asserts it names only the kinds `apply` reconciles, stays multi-document,
  carries no plaintext secret, and defines the agent the call beside it hires.
  The case study moved from the seventh section to the third and now carries
  the attribution its numbers require on the page where they appear, one
  production estate over a stated window. The page gained a second
  registration ask after the proof, so the gap between asks falls from about
  1,300 words to 539. `/faq` keeps its links, folded into the limits section
  instead of a band of its own. Calls to action name a result instead of
  reading: "See it work in 40 lines", "Browse the endpoints", "Follow the
  whole incident", "Get the answers". The word "row" leaves the marketing
  pages, which described the primitives after a database table; they are
  templates. The footer loses the site's only contraction and stops offering
  something for "teams", which the same page's limits deny.

- **The homepage says each thing once.** The page had grown to about 2,630
  rendered words across sixteen sections, and roughly half of that was the
  same claims restated. The concurrency rule was interpolated in four places,
  parked time cost nothing in five, and three sections were three passes over
  the same six mechanisms: a "you did not set out to run a sandbox platform"
  grid that previewed each one, the sections that explained them, and a "what
  you stop building" grid that recapped them. It is one pass now. Each of the
  six question cards carries the question and the clause that closes it, and
  the feature grid is gone. The ceiling rule is stated once, on the price
  card. The two `/faq` buttons that sat four hundred words apart are one
  block, and the two adjacent sections about apps built on the API are one
  section. Nothing was dropped that is not said somewhere else on the page or
  on the page it links to: about 1,363 words, down 48%, thirteen sections.
  Also fixes `organisations` on the homepage and `/faq`, which the license and
  enroll pass missed.

- **`/self-hosted` reads on a phone, and the site spells license the American
  way.** The page was built at desktop widths: fixed `px-6` gutters, `py-16`
  section rhythm and `p-6` cards at every size, two code blocks that wrapped
  mid-token rather than scrolling, and a numbered ladder whose left margin
  pushed its own text off a narrow screen. Every one of those is a breakpoint
  now, the code blocks scroll in their own box, and the two call-to-action
  rows go full width before they go side by side. No copy moved. Separately,
  the site mixed British and American forms; `licence` and `enrol` are the
  British ones, and the visible text now uses `license` and `enroll`
  throughout. `licence_parts/0`, the `:licence` key and `data-role="licence"`
  keep their spelling, because they are identifiers and one is a test
  selector, and the license names (`AGPL-3.0-or-later`, `Elastic 2.0`,
  `Apache-2.0`) were never in question.

- **The homepage sells infrastructure to builders, not an agent to a
  consumer.** The pitch read as a coworker product ("hire an agent by role",
  "close the laptop", "build a roster"), which is the wrong reader. The one
  who arrives is building something whose users will meet the agent, and the
  cost they are weighing is not how long the machine takes to build but that
  they would own it afterwards. The headline says so, and the subheadline
  names the maintaining. The problem section is the six questions between a
  working demo and a shipped feature, each answered with the mechanism that
  settles it: where it runs, how it gets a token that can push, how the work
  gets out, how you get an answer instead of a transcript, who turns the
  machines off, and what starts one when nobody is at a keyboard. The SDK call
  moves up to sit directly under them. The teammate section becomes the
  durable thread a builder maps onto ids they already hold, the roster section
  becomes how a hundred tickets get worked at once, and both new objections
  are the ones a builder asks first: whether their own users need accounts
  here, and whether any of this works outside writing code. The apps are
  reframed as reference implementations of the thing the reader is about to
  write. The scale section states the hosted ceiling out loud and sends
  anybody who needs more to `/self-hosted`, which now names that as the second
  reason to go there.

- **Two snippets on the marketing site were not runnable.** The homepage's SDK
  call printed `run.output`, which is not a field on `RunResult`; a reader who
  pasted it got `undefined`. It now prints `run.text` and passes a
  `channelId`, which is the option that binds a conversation to an id the
  caller already has. The `/integrations` pipeline scenario ran
  `fountain conversations create --external-id`; neither the command nor the
  flag exists, and the real one is `fountain run <agent> --prompt`.

- **The marketing footer wraps into groups instead of one long row.** Ten
  links on one line had gone cramped as pages were added, and the row was
  ordered by nothing. They sit under Product, Learn and Account now, with the
  brand and its one-line description in the first column and the copyright,
  Terms and Privacy on a rule below. A deployment that is not the marketing
  site drops the Product group whole rather than heading an empty column, so
  a self-host still gets a footer with only the two groups it can fill.

- **`/self-hosted` leads with the bring-up.** The compose block is on the
  first screen beside the argument rather than three sections down, the
  headline is the reason to run it yourself, and the four things a bring-up
  needs — Docker with Compose v2, the registry it pulls from, the Postgres it
  brings with it, and `PUBLIC_URL` — are stated before the commands instead of
  discovered during them. A "know it worked" card carries the health probe and
  says that a refused connection during the cold start is the normal state.
  The ownership ladder moves ahead of the rationed features, because for
  anybody weighing hosted against self-hosted it is the argument rather than
  the appendix. The page also answers how to tear an instance down.

- **The three apps we build ourselves lead the marketing pages.**
  Conversations, Team and Workbench were scattered through `/built-with`, one
  of them filed under "For engineers" and the other two last on the page. They
  are now a tier of their own: a featured band straight under the hero on
  `/built-with`, a section of their own on `/`, and a band on `/self-hosted`
  answering what a fresh instance serves, with the `API_CORS_ORIGINS`,
  `CONVERSATIONS_APP_URL` and `TEAM_APP_URL` lines that point them at it. Each
  card says what the app is like (a chat client where the model has a real
  computer, a group chat whose contacts are agents, multiplayer engineering)
  and who it is for. The tier is a key on the roster entry rather than a
  second list, so a featured card cannot drift from `/built-with`, and the
  suite checks the three lead the page and render exactly once. The README and
  the manual's `The console, the apps, and the API` name all three as well;
  that page counted two.

### Removed

- **`.sops.public-key`.** ADR 0032 deleted `.sops.yaml` because the only
  SOPS-encrypted file in the repo had stopped existing; the age public key it
  paired with was missed in that sweep. SOPS itself was retired across the
  operator's cluster in 2026-07 for two-tier Infisical, whose bootstrap
  credential its manifests describe as the replacement for the SOPS age key.
  Nothing in this repo or in home-cloud read the file or the key. A public key
  leaks nothing by sitting there, but a live-looking secrets artifact in the
  repo root implies a workflow that does not exist.

### Fixed

- **`interrupt` wakes a dead conversation server before answering 404**
  (#1179, #1180). A `running` conversation can outlive its GenServer (a
  deploy, a Horde rebalance), and `POST .../interrupt` answered
  `{:error, :not_running}` for it, indistinguishable from a conversation that
  does not exist, so a stuck autonomous turn sat `running` for hours with no
  way to end it. Interrupt now mirrors `send_prompt`'s wake-on-miss: if the
  row says `running`, it wakes the server, which reattaches to a live session
  or closes the orphaned turn itself.

- **The stylesheet URL carries its content hash, so a deploy cannot land on
  a cached one** (#1259). `/assets/tokens.css` was served with a four-hour
  max-age under an unchanging URL, and #1258 shipped correct markup against a
  stale sheet, so the homepage rendered with the ink tokens undefined. The
  layout links `tokens.css?v=<hash>` computed at compile time, and a guard
  fails if the bare path returns. Applies to the console as well as the site.

- **Compose forwards the variables the guides tell you to set** (#1215,
  #1216, #1217). `API_CORS_ORIGINS`, `OAUTH_CLIENTS`, `CONVERSATIONS_APP_URL`
  and `TEAM_APP_URL` were read by `config/runtime.exs`, documented, and passed
  to the container by nothing, so following the deploy guide changed nothing
  and the Conversations app failed CORS; the three features `/self-hosted`
  says you switch on (`FEATURE_FLAGS_ON`, the AgentMail and AgentPhone keys,
  every `BROKER_*` variable, eighteen in all) were in the same state.
  `docker-compose.yml` forwards all of them, the four app-facing keys as bare
  `KEY` so unset keeps the default and `KEY=` still means "no such app".
  `.env.compose.example` ships `SECRET_KEY_BASE` and `MASTER_SECRETS_KEY`
  commented out, because the quick start appends both and the blank line
  above left two copies. The deploy guide names Docker with Compose v2,
  openssl and reachable ghcr.io as prerequisites, waits for `healthy` before
  the probe, and has a teardown. Guards assert every `>> .env` line in
  `docs/` and every variable `rationed_features/0` names is forwarded.

- **A transient Sprites timeout while writing the runtime's config no longer
  fails the conversation.** The first filesystem call into a freshly created
  sprite timed out once in prod (`Req.TransportError{reason: :timeout}`) and
  `Claude.write_config/2` crashed on it, marking the sandbox and conversation
  `failed` at the very step the provision `with` had marked best-effort. The
  `.mcp.json` and settings writes (and gemini's) are idempotent and now retry
  through `Fountain.Retry` like every other sandbox write; a write that still
  fails returns `{:error, {:runtime_config, path, reason}}`, which the fresh
  provision treats as a real failure (an agent must not run without its MCP
  servers under a `provision/done`) and the wake path logs and continues.

- **`fountain run` says why a turn failed.** A `turn`/`failed` event carries
  the runtime's reason, and the CLI printed only `turn failed`. It prints the
  reason now, and when the reason is the runtime's "Authentication required"
  (what a sandbox reports when the account has no inference credential, the
  quickstart step most easily skipped) it names the fix: add one under
  Account, then Inference keys. The exit code is unchanged.

- **The session title no longer opens a phantom "(background task follow-up)"
  turn after every claude turn** (#1300). The claude adapter generates the
  session title asynchronously and writes its `session_info_update` about a
  second after the prompt response — out of turn — and the server read any
  out-of-turn protocol line as a background task narrating a follow-up (#817).
  So nearly every claude turn was followed by a synthetic autonomous turn
  holding the conversation `running` for the full ten-minute quiet window:
  a phantom user bubble in the transcript, idle park deferred, and the window
  billed as turn time. On the hosted instance, 167 of the 190 autonomous turns
  in the fourteen days before the fix held exactly one such line and nothing
  else. Session metadata (`session_info_update`, `available_commands_update`,
  `current_mode_update`) is now classified as describing the session rather
  than the agent talking: it opens no autonomous turn, does not extend one
  already open, and still lands on the transcript when a real turn is in
  flight. Real background follow-ups — updates that carry agent output or
  tool calls — behave exactly as before.

## [0.14.0] — 2026-08-25

### Upgrade notes

- **The hosted instance is `managoat.com`.** Self-hosters are unaffected:
  `PUBLIC_URL` is yours, and a CLI or SDK pointed at your instance
  (`FOUNTAIN_BASE_URL`, `fountain auth login`, `baseUrl`) keeps pointing
  there. Only the compile-time fallback changed.

- Connections are opt-in: without `GOOGLE_OAUTH_CLIENT_ID` /
  `GOOGLE_OAUTH_CLIENT_SECRET` the *Connections* page lists no provider and
  nothing else changes. One migration adds the `connections` table.

### Added

- **An *Open source* page at `/docs/open-source`, and ADR 0034 on why the
  project has no site of its own.** With the hosted instance branded
  Managoat (#1177), the page states the licence split, the two names and
  where everything lives; the README licence section links it. The decision
  is the PostHog/Sentry shape: the product site is the project site, `/docs`
  is the manual, the repo README is the front page, no second domain.

- **Connections: sign in to Google once, and agents get Gmail without ever
  holding the credential** (#1178). For accounts the egress broker is on for,
  the console's new *Account → Connections* page runs Google's
  authorization-code flow (`access_type=offline`, `prompt=consent`) and
  Fountain keeps the refresh token DEK-encrypted like any tenant secret.
  Two ways an agent uses it, neither of which puts a Google token in a
  sandbox:
  - **A Fountain-served Gmail MCP server.** An agent's `mcp_servers` names
    the connection — `{"gmail": {"connection": "<id>"}}` — and the
    conversation gets `gmail_search`, `gmail_get_thread`, `gmail_get_message`,
    `gmail_send`, `gmail_reply`, `gmail_modify_labels` and
    `gmail_list_labels`, served at `POST /api/mcp/gmail/:conversation_id/:connection_id`
    and authenticated by the callback token the sandbox already holds. The
    token is refreshed server-side per call; a revoked connection answers
    `connection revoked`, not a 401.
  - **A brokered `GOOGLE_ACCESS_TOKEN`.** The access token is a synthetic
    secret brokered like an inference key (ADR 0019): the sandbox holds a
    placeholder, the broker attaches the value as a bearer to
    `gmail.googleapis.com` / `www.googleapis.com`, and a binding of your own
    on that name sends it to an MCP server you run instead. Tokens rotate
    hourly; the conversation server re-uploads a rotated one at the next
    turn kick, so a shared sandbox (ADR 0023) outlives them.
  - `GET/DELETE /api/connections`, `GET /api/connections/providers`, in the
    OpenAPI spec and the TypeScript SDK (`client.connections`). Configured
    by `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET`.

### Changed

- **The hosted Fountain is `managoat.com`** (#1177). The CLI's and the
  TypeScript SDK's compile-time default base URL, the docs, the sample
  compose and k8s files and the hermes plugin now name the new host; the
  old `fountain.inevitable.fyi` keeps answering and redirects. Self-hosters
  who set `FOUNTAIN_BASE_URL` are unaffected. SDK 1.8.0 carries the change.

### Fixed

- **Brokered sandboxes now trust the egress broker's MITM certificate across
  the Python and Rust toolchains, not only Node.** A brokered `uv sync`,
  `uv python install`, `pip install` or `cargo fetch` failed with
  `invalid peer certificate: UnknownIssuer` the moment it reached a
  MITM'd host, because those tools carry their own bundled roots and ignore
  the OS trust store where the broker CA is installed. `Fountain.Broker.sandbox_env/1`
  now also sets `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE` and `CARGO_HTTP_CAINFO`
  to the full system CA bundle (real roots plus the broker CA — never the
  broker CA alone, which would break non-brokered hosts like PyPI), and
  `UV_NATIVE_TLS=1` so uv reads that store instead of its bundled webpki roots.

- **The environment edit page no longer 500s when a `packages` value is a
  string instead of a list.** `packages` is a free map, and manifests had
  stored a version string under a manager the provisioner does not read
  (`"node" => "24"`), which `Enum.join/2` refused. A non-list value now
  renders as-is and round-trips as a one-item list.

- **A refused Agent Vault create is checked against the vault list before
  it fails a prepare** (#1184). The vault answered 500 for a duplicate name
  where the contract says 409, which failed every reattach of a brokered
  conversation after its first idle; `ensure_vault` now consults the list
  on a refused create and proceeds when the vault is there.

- **`gmail_search` no longer 500s** (#1183): Gmail's multi-valued query
  params (`metadataHeaders`, `labelIds`) are encoded as repeated keys.

## [0.13.0] — 2026-08-25

### Upgrade notes

- **Fountain is no longer MIT licensed** (ADR 0027, #998). From this release
  the server under `apps/fountain` is AGPL-3.0-or-later, `ee/` is Elastic
  License 2.0, and `cli/` and `sdk/typescript` are Apache-2.0. Releases
  through v0.12.0 stay MIT. Details under Changed, in `LICENSE` and in
  `decisions/0027-agpl-relicensing.md`.
- **Subscription plans are gone; credits are the product** (ADR 0030,
  ADR 0031). The upgrade is not a no-op for a deployment that had
  `BILLING_ENABLED=true`:
  - *Cancel live subscriptions in Stripe by hand.* Nothing on this release
    reads, renews or cancels one. Comped accounts carry over
    (`subscription_status = 'comped'` becomes `users.comped`).
  - *Env vars no longer read:* `STRIPE_PRICE_ID`,
    `STRIPE_PRICE_MONTHLY_CENTS`, `STRIPE_PRICE_ID_CONTACT`,
    `STRIPE_CONTACT_PRICE_CENTS`, `DEFAULT_PLAN`, `CREDIT_PRICING_SINCE`,
    `CREDIT_ENFORCE`. New: `CREDIT_PACKS_CENTS`, `CREDIT_TURN_HOUR_CENTS`,
    `CREDIT_OPENING_CENTS` / `CREDIT_OPENING_DAYS`, `CREDIT_NUMBER_CENTS`,
    `CREDIT_INBOX_CENTS`, `CREDIT_EMAIL_MESSAGE_CENTS`,
    `CREDIT_SMS_MESSAGE_CENTS`, `SANDBOX_RESERVE_CENTS`, `SANDBOX_CAP_FLOOR`,
    `SANDBOX_CAP_CEILING`, `SANDBOX_FLEET_CEILING`. See `.env.example`.
  - *Run `Fountain.Release.rebuild_credit_lots()` once after the upgrade*
    (`docs/guides/operate/run-a-release-task.md`). It replays every ledger
    into lots and is safe to rerun.
  - *The rolling deploy is not seamless across this boundary.* Two
    migrations drop columns a v0.12.0 pod still selects (`users.plan`,
    `subscription_status`, `stripe_subscription_id`, `comped_contacts`, ...).
    A v0.12.0 pod that is still serving after the migrations run returns
    errors until it is replaced. Run the migrations once the old pods are
    gone, or accept a brief window of errors during the roll.
  - *Breaking API and SDK changes* (SDK 0.2.0 → 1.0.0): `GET
    /api/account/billing` loses `status`, `plan`, `trial_ends_at`,
    `current_period_*`, `cancel_at_period_end` and
    `usage.turn_hours_included` / `remaining`, and gains `credits`,
    `sandbox_cap` and `comped`; `POST /api/account/billing/portal`,
    `POST /api/account/billing/checkout`, `POST
    /api/admin/users/:id/extend-trial` and `.../resync-stripe` are removed;
    admin user objects lose `subscription_status` / `plan` /
    `comped_contacts` and gain `comped`; credit is bought at `POST
    /api/account/billing/credits/checkout`.
- **`BILLING_ENABLED` is `CREDITS_ENABLED`** (#1144). The old name is still
  read for one release and logs a deprecation warning at boot; rename it in
  your environment before the next minor. The Oban queue `billing` is
  `credits` (a migration moves any waiting job). `FountainWeb.Live.BillingLive`,
  `BillingApiController` and `Fountain.Emails.BillingEmails` are
  `CreditsLive`, `CreditsApiController` and `CreditsEmails`; routes and API
  paths are unchanged.
- **The conversation and team UIs are separate apps** (#869). Self-hosted:
  either set `API_CORS_ORIGINS` and `OAUTH_CLIENTS` so the hosted apps can
  reach your API, or set `CONVERSATIONS_APP_URL=""` and `TEAM_APP_URL=""` to
  say this deployment has none. The old `/conversations*` and `/team*` paths
  redirect. The full note is under Changed.
- **`SANDBOX_MAX_LIFETIME_HOURS` defaults to `0`** (#1076). The 24-hour
  destroy backstop is off unless you set it.
- **`/` is a plain front door unless `MARKETING_SITE=true`** (#1015). A
  deployment that wants the sales page must set it.
- **`SANDBOX_RUNNERS_ENABLED` defaults to `true`** (ADR 0022, #833). Any
  tenant may attach their own machine as a sandbox backend; set it to
  `false` to keep the hosted providers only.
- **Building the CLI needs Go 1.26** (#919), matching `cli/go.mod`. The
  release binaries are unaffected.

### Added

- **Credits are the product** (ADR 0030, ADR 0031; #1094–#1101,
  #1108–#1110, #1114, #1116, #1122). There are no plans, tiers, trials or
  subscriptions: an account holds a prepaid balance in cents
  (`credit_ledger`, cached on `users.credit_balance_cents`), every door that
  spends is gated on it (`402 insufficient_credits` with `upgrade_url`;
  in-flight turns finish and may go negative), and Stripe is only the till:
  packs (`CREDIT_PACKS_CENTS`) sell through one-time Checkout and
  `charge.refunded` / `charge.dispute.created` claw back. Closed turns on
  platform-paid providers burn `CREDIT_TURN_HOUR_CENTS` (default 25) against
  turn seconds; teammate numbers and inboxes rent
  `CREDIT_NUMBER_CENTS + CREDIT_INBOX_CENTS` a month up front with a
  seven-day grace before release; email and SMS burn
  `CREDIT_EMAIL_MESSAGE_CENTS` / `CREDIT_SMS_MESSAGE_CENTS` when set. Every
  credit row is a lot with `remaining_cents`, consumed in a fixed order (the
  lot a debit names, earliest expiry, then purchased). Verification grants
  `CREDIT_OPENING_CENTS` ($5) expiring after `CREDIT_OPENING_DAYS` (14).
  Runway emails go out at 20% and at zero; `POST
  /api/admin/users/:id/credits` grants; `users.comped` is the one operator
  lever. The balance, packs and ledger show on `/account/billing`, the
  dashboard, `/admin/users`, `/admin/finance` and `GET /api/account/billing`
  (`credits`, `sandbox_cap`, `comped`). SDK 1.0.0.
- **The concurrency cap is funded by the balance, under a fleet ceiling**
  (#1114). `sandbox_limit` is `sandbox_limit_override` if set, else
  `clamp(balance ÷ SANDBOX_RESERVE_CENTS, SANDBOX_CAP_FLOOR, SANDBOX_CAP_CEILING)`
  (defaults $2 / 2 / 20; comped and billing-off get the ceiling).
  `SANDBOX_FLEET_CEILING` bounds live sandboxes across every tenant under a
  global lock and refuses as `503 fleet_full` with `Retry-After`. Plans no
  longer size the cap.
- **A per-tool permission policy, and an `ask` that reaches a person**
  (ADR 0014 gate 3, ADR 0015 gate 4; #947, #950, #952, #960, #963, #965,
  #968). Every runtime used to run with its rail off behind a constant
  auto-allow in the ACP peer. `permission_policy` on the agent (console
  form, `POST` / `PATCH /api/agents`, returned on agent JSON) maps ACP tool
  kinds to `allow` / `deny` / `ask` plus a default; a launch may only narrow
  it. An `ask` surfaces as a `permission_request` block on the transcript
  with a Fountain-minted `request_id`, is resolved by `POST
  /api/conversations/:id/requests/:request_id` (a `request` stage event
  records the answer), is forwarded verbatim to the editor that spawned
  `fountain acp`, and is denied on expiry, disconnect or dismissal. A
  reattach after a deploy does not re-ask a held request. opencode never
  asks, so a policy on an opencode agent is refused rather than stored
  (#961).
- **Gemini runs on the ACP path** (#955, #964, #969). The last runtime on
  the legacy spawn path moves to ACP: one session, resume, MCP and
  permission mechanism for all four runtimes, and the last vendor
  permission-bypass flag (`--approval-mode yolo`) is deleted. A workaround
  stops `gemini --acp` erasing the session it is asked to load
  (google-gemini/gemini-cli#28775).
- **A self-hosted runner: your own machine as a sandbox backend** (ADR 0022,
  #833). `fountain runner` is a Go daemon that dials out to Fountain over one
  WebSocket (no inbound port, works behind NAT) and serves sandboxes as
  directories on that machine, so an agent's disk never parks and nothing is
  billed by the minute. Trusted mode: the agent runs as the daemon's user
  with the daemon's network. `GET /api/runners`, `DELETE /api/runners/:id`,
  an `/account/runners` page, `provider: "runner"` on the agent;
  `SANDBOX_RUNNERS_ENABLED` (default true). Runner turns are never priced.
- **Teammates that know each other: the `fountain-team` MCP and a bundled
  `/create-team` skill** (#852, #855). Every team-channel conversation
  carries an MCP server Fountain serves at `POST /api/mcp/team/:conversation_id`
  with `list_teammates`, `get_teammate`, `send_to_teammate`, `read_teammate`
  and `wait_for_teammate` (blocks server-side up to 90 s for a reply instead
  of polling). `/create-team` is a second bundled skill beside `fountain`: a
  five-question Q&A that proposes a roster and, only after a yes, creates
  the agents and teammates.
- **`POST /api/support/reports`: "Report a problem" with context** (#843,
  #844). A client sends a category (`bug`, `stuck`, `question`, `idea`,
  `other`), a message, a context map and an optional screenshot; Fountain
  forwards it as a GitHub issue (`SUPPORT_GITHUB_REPO` +
  `SUPPORT_GITHUB_TOKEN`) and/or mail to `SUPPORT_EMAIL`, and keeps the row
  either way. Audited as `support.report.created`, never the message.
- **A missing provider key is collected when a model first needs it**
  (#841, #842). The agent form asks for the OpenAI or Gemini credential
  inline the first time a model on that provider is chosen, instead of
  asking for all four up front.
- **`?blocks=true` on the team stream, and `Last-Event-ID` declared**
  (#988). `/api/team/stream` returns server-parsed blocks like every other
  feed instead of 422ing on the parameter; the SDK no longer special-cases
  it.
- **The finance panel shows the provider's invoice beside the computed
  figure, and the dropped-event count** (#1038, #1102). `/admin/finance`
  records what each provider actually charged for a month
  (`provider_invoices`) and puts the computed cost and the delta next to it;
  `[:fountain, :usage, :dropped]` is shown since boot so a period built on an
  incomplete record says so.
- **`PRODUCT_NAME` brands the chrome** (#1134, #1137, #1141). A deployment's
  brand drives the console and marketing headers, `<title>`, the sign-in
  and consent pages, the emails, `/terms`, `/privacy` and the © line; the
  manual at `/docs`, the CLI, env vars and `apiVersion` stay "Fountain", the
  engine. Default `Fountain`, so nothing changes unless set.
- **Admin is one section per page** (#1041). `/admin` (funnel + tiles),
  `/admin/users`, `/admin/sandboxes`, `/admin/billing` and
  `/admin/activity` (paginated privilege trail) share a tab bar; the single
  page that re-ran every query every ten seconds is gone.
- **The `fountain-contributor` canned agent** (#1010, #1044, #1050).
  `examples/agents/fountain-contributor/` is one `fountain apply` manifest
  (environment, vault, agent) that rebuilds a maintainer's session in a
  sandbox, with a README on cost, first-run time and what the vault needs; a
  Go test keeps every example parsing.
- **Traces export to a collector once one is configured** (#979). Setting
  `OTEL_EXPORTER_OTLP_ENDPOINT` (OTLP over HTTP/protobuf, port 4318) is the
  whole switch; unset still exports nowhere.
- **The egress trail, ADR 0019 gate 4.** `GET /api/conversations/:id/egress`
  lists what a brokered conversation actually sent out: each request's
  host, the binding that matched (and so the credential attached), the
  status and latency, refusals included. A conversation's vault on the
  broker now keeps its request log after the conversation ends (credentials,
  services and sessions are stripped; the vault stays) for
  `BROKER_LOG_RETENTION_HOURS`, and a daily job deletes older ones.
- **Inference credentials through the broker, ADR 0019 gate 3.** On a
  brokered account the runtime's credential (`CLAUDE_CODE_OAUTH_TOKEN` or
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`) is a vendor-shaped
  placeholder in the sandbox and the broker substitutes the value on
  requests to the provider's host. The OAuth-refused fallback re-prepares
  the broker instead of injecting a plaintext key.
- **`substitute`, the default binding shape.** A binding now needs only a
  host: the broker replaces the secret's placeholder wherever it appears in
  a request (header, query, path, body), so the agent sends the shape the
  API wants. Every binding shape carries the substitution; the header
  shapes remain for an API the agent cannot address itself, and basic auth
  for a value the client encodes.
- **`limited` environments at the broker, ADR 0019 gate 2.** On a brokered
  account a `limited` environment is no longer refused: the sandbox's policy
  stays the broker-only floor, and the broker enforces `allowed_hosts`
  (unmatched-host policy `deny`, one passthrough service per listed host) so
  an unlisted host is refused with a 403 that names it. `unrestricted` is
  passthrough at the broker, as before.
- **Secret bindings, ADR 0019 gate 1b.** On an account the broker is on for,
  a secret can be bound to the hosts it is a credential for and the way it
  is sent (bearer, basic, API-key header, custom headers). A bound secret
  reaches the sandbox as a placeholder and the broker attaches the value; an
  unbound one reaches it in the clear as before. A console page at
  Account, Credential bindings (only shown when the broker is on), the
  `/api/secret-bindings` routes with a 35-entry preset catalog, and every
  binding change in the audit trail. Replaces gate 1a's hardcoded GitHub
  catalog, which stays as the default for `GITHUB_TOKEN` / `GH_TOKEN` with
  no bindings.
- **Egress credential brokerage, gate 1a (ADR 0019, #1090).** `Fountain.Broker`
  and the provisioning wiring for an Agent Vault forward proxy: a brokered
  sandbox holds `__github_token__` where `GITHUB_TOKEN` was, the real value is
  attached at the proxy, and the proxy's host is the one host it may reach.
  Off unless `BROKER_URL` is set, and then only for the tenants in
  `BROKER_TENANTS`; an unbrokered conversation provisions byte-for-byte as
  before. No broker is deployed and no tenant is flipped by this change.

- **Turns carry `origin`.** `user` for a prompt somebody sent, `autonomous`
  for a turn the server opens for a background cycle the agent runs after
  its prompt was answered — a `Monitor` firing, a scheduled wake-up. On
  `GET /api/conversations/:id/turns` and in the SDK (0.1.9). Part 2 of 3
  for #817: additive and inert, nothing writes `autonomous` until part 3
  moves the ACP connection to the wake.

- **A persistent home is checkpointed when it parks.** With
  `CHECKPOINT_CREATION_ENABLED=true`, on a provider that has checkpoints
  (Sprites), both park paths — the server's idle and ceiling reclaim, and
  the reaper's park of a home with no live server — take a checkpoint of
  the machine first and record it on the sandbox (`checkpoint: {id, at}` on
  `GET /api/sandboxes[/:id]`) and as a `checkpoint` stage on every live
  transcript. A checkpoint is scoped to the machine that made it: it can
  roll that home back to its last park, and it cannot rebuild a home that
  is gone — a lost machine is still rebuilt from environment, vault and
  repositories. Every park adds one and none are deleted yet. Ephemeral
  sandboxes are never checkpointed. The flag is now read from the
  environment; it existed only as test config before. ADR 0023 (#1073).

- **The last three launch doors take `sandbox_mode` and `sandbox_id`.**
  `fountain acp` gets `--sandbox-mode` and `--sandbox` for every session it
  opens, and a client may name either per session in `session/new` `_meta`
  (`sandboxMode`, `sandboxId`). A hosted Buzz agent carries `sandbox_mode`
  on its identity (`POST /api/buzz/agents`, the provider's settings form),
  passed to its harness as `--sandbox-mode`; a change restarts the harness
  like the other launch fields. The sandbox exports `FOUNTAIN_SANDBOX_ID`
  beside `FOUNTAIN_CONVERSATION_ID`, so the `fountain` skill can put a child
  onto the parent's own machine with `sandbox_id`. Channel resume still takes
  the agent's default, on purpose. ADR 0023 step 8, #1070.

- **Reset a persistent sandbox.** `DELETE /api/sandboxes/:id` destroys an
  agent's home so the next launch on the same agent, environment and vault
  builds a clean machine — the conversations on it are kept, idle, and each
  one's next prompt lands on the fresh home together with the others. Only a
  live `persistent` sandbox resets (`422 sandbox_not_resettable`), and not
  while a conversation on it is mid-turn (`409 sandbox_mid_turn`). Also
  `fountain sandbox list|show|reset` and the SDK's `resetSandbox(id)`.
  Audited as `sandbox.reset`. Until now the only reset was to delete the
  agent (#1071, ADR 0023 step 5).

- **A persistent sandbox per agent — the agent's computer.** An agent's
  `sandbox_mode` is `ephemeral` (a sandbox per conversation, the default and
  today's behaviour) or `persistent`: one machine per agent identity (agent,
  environment, vault) that every conversation of that identity lands on and
  shares, provisioned on the first launch and attached to on every later
  one. A home survives a conversation ending, is parked rather than
  destroyed at the ceiling, and is destroyed when its agent is deleted. A
  launch may name the other mode (`sandbox_mode` on `POST /api/conversations`,
  `fountain run --sandbox-mode`, the SDK's `run({ sandboxMode })`); a second
  launch while the home is still provisioning gets `503 provisioning`.
  Sandboxes carry `mode`. ADR 0023 gate 6.

- **A second conversation on a sandbox you already have.** `sandbox_id` on
  `POST /api/conversations` attaches the new conversation to an existing
  machine instead of provisioning one: it must be yours, `ready` or
  `suspended`, and built for the same agent, environment and vault
  (`sandbox_not_found`, `sandbox_not_attachable`,
  `sandbox_identity_mismatch`, `sandbox_runtime_mismatch` say which rule
  refused). The conversation opens idle on that disk and a prompt wakes it;
  several conversations then run there at once. `GET /api/sandboxes` and
  `GET /api/sandboxes/:id` list the caller's machines with the conversations
  on each and which is mid-turn. Sandboxes now record the `agent_id` and
  `vault_id` they were built for (backfilled). `fountain run --sandbox` and
  the SDK's `run({ sandbox })`, `sandboxes()` and `sandbox(id)` carry it.
  ADR 0023 gate 3.

- **Agent config versioning with diff and rollback.** Every config change
  writes an immutable version (version 1 backfilled for existing agents);
  the console's History page (`/agents/:id/versions`) diffs each version
  against its predecessor and offers one-click rollback, applied as a new
  edit through the same validation as any other — history is never
  rewritten. Conversations record the agent version they launched under
  (provenance only; the live agent row still drives the sandbox), and
  version history joins the account export. ADR 0029.

- **Vault secrets can carry an expiry date.** `expires_at` is optional
  metadata on a vault secret: the console shows staleness (last-updated age
  and expiry status) on the vault page, and a daily sweep emails the owner
  once per recorded expiry before the date arrives — 7 days ahead by
  default (`SECRET_EXPIRY_NOTICE_DAYS`; `0` disables). Nothing is enforced
  on the date: an expired secret keeps being injected, because a missing
  env var fails worse than a stale one. The API accepts and returns
  `expires_at` on vault secrets; values remain write-only. Changing the
  expiry only works together with a value write today — a value-less
  metadata update is #1053.

- **The finance panel's rate card is filled in, and rates may be fractional.**
  `/admin/finance` shipped reporting hours with no money in them until an
  operator supplied prices (#1025). The published rates are now set:
  `PROVIDER_COST_BASIS=turn`, `PROVIDER_HOURLY_CENTS`, and the AgentMail and
  AgentPhone per-unit and per-message rates.

  **The basis is the load-bearing choice.** Sprites sleeps a sandbox after 30
  seconds of inactivity and bills "just the CPU hours, RAM hours and GB-hours
  of storage you use while the Sprite is awake", so the billable unit is close
  to turn time and not the sandbox's wall-clock lifetime.
  `SandboxUsage.active_seconds` reports the latter — it subtracts only the
  explicit suspend/resume of #665 and knows nothing about the provider's own
  auto-sleep. Over one month those two read 1,908h against 16,659h, so the
  basis is worth 9x and the rate is worth rather less.

  Rates are fractional now because per-message rates are. AgentMail bills
  about $0.002 an email; as a whole number of cents that is zero, and the
  panel would have reported email as free however much of it an agent sent.
  Each cost component still rounds to whole cents exactly once, at the end,
  so 400 emails at 0.2c is 80c rather than 400 roundings of nothing.

  One rate card prices every provider on one basis, which is right only while
  the providers behave alike. `sprites` (asleep after 30s) and `e2b` (billed
  until paused) do not, and a deployment with real traffic on both wants a
  per-provider basis. It does not bite today: every hour on the bill is a
  Sprites hour.

- **The public pages are session recorded, and now say so.** This started as a
  side effect rather than a decision: session replay is switched on in the
  PostHog *project*, and posthog-js records whenever it is, so loading the
  library for visitor analytics turned replay on for the landing page, the
  legal pages, the manual and the auth flow without anyone choosing it. Found
  in production, kept on review — replay of the sign-up flow answers "where did
  this funnel lose people" in a way a pageview count cannot — and written down,
  because a capability nobody chose is one nobody maintains. The console is
  still not recorded; it loads no library. The layout now states
  `session_recording: { maskAllInputs: true }` rather than inheriting it, so
  the masking is visible to a reader of the file and cannot change quietly when
  a dependency's default does. It covers the email address on `/auth/login` and
  `/auth/register`; passwords are masked by rrweb regardless. ADR 0028.

- **The public pages report visitors.** Fountain's analytics were server-side
  only, and `capture/4` drops an event with no account attached — so the
  landing page, the legal pages, the manual and the whole auth flow sent
  nothing at all. Nobody who was not already signed in was counted anywhere,
  and the acquisition funnel had no top. Those pages now load `posthog-js`,
  which is the only thing that has the facts the question needs: sessions
  (the project's server-side pageviews had produced **0** sessions against 108
  pageviews, so every web-analytics KPI — bounce rate, session duration, entry
  pages — had no input), referrers, UTM parameters, and devices. Anonymous
  readers do not mint person profiles (`person_profiles: "identified_only"`),
  so a person still appears when an account does. `POSTHOG_BROWSER_CAPTURE=false`
  turns it off and leaves server capture untouched. ADR 0028.
- **The visitor and the account become one person at sign-in.**
  `FountainWeb.Plugs.AnalyticsIdentity` reads posthog-js's cookie and merges
  the anonymous visitor into the account, so the pages someone read before
  signing up join their history. It keys on the session transition rather than
  sitting at each of the five places a session is established, for the reason
  ADR 0013 gives: a sixth door would otherwise be one forgotten line away from
  a silent hole. Doing it from the server is what lets the console stay free
  of a snippet.
- **API usage is answerable.** The `:api` pipeline's request-log rows were
  refused wholesale, which left "which endpoints does anyone call", "is the SDK
  erroring" and "did that release change API usage" with no answer while the
  audit trail held the data for all three. They now arrive as a single
  `api.request` event carrying `method`, `route`, `status` and `status_class`.
  One event name, with the route as a *property*: the original refusal was
  about the event *name* (73 distinct request-line names in one day, each its
  own PostHog event definition in the taxonomy everyone reads), and a property
  is where PostHog can break down by a value the router bounds.
- **A finance panel at `/admin/finance`.** `/admin` had an MRR tile with no
  cost beside it and a sandbox-hours table with no money in it, so the only
  question an operator asks a finance page — which accounts cost more than
  they pay — had no answer anywhere. The new page puts revenue, platform
  spend and the margin between them on one row per tenant, worst margin
  first, with a month picker back through the last six.

  It reports **no money it was not told**. Fountain's own costs are nowhere in
  this codebase (provider prices are per-machine-size and negotiated;
  AgentMail and AgentPhone bill per unit and per message), so cost is priced
  from a rate card in config: `PROVIDER_HOURLY_CENTS`,
  `AGENTMAIL_INBOX_CENTS`, `AGENTPHONE_NUMBER_CENTS`,
  `AGENTMAIL_MESSAGE_CENTS`, `AGENTPHONE_MESSAGE_CENTS`. Set none of them and
  the panel still works, in hours, inboxes, numbers and message counts. An
  unpriced line renders `—` and never `$0.00`, and the `nil` propagates to the
  total: a cost that quietly omitted the provider nobody priced would read as
  a cheap tenant, most convincingly on the expensive ones.

  Every tenant row carries both plans the trial split introduced: the tier the
  subscription is for, which prices its revenue, and the plan whose numbers
  apply today, which the allowance column is measured against. A trialing
  account read through the first would be measured against hours it has not
  bought yet, and would report as inside an allowance it is over.

  It also does not assume **which** hours a provider bills. The rate can
  multiply every hour a sandbox was awake, or only the hours with a prompt in
  flight, and a toggle on the page switches between the two
  (`PROVIDER_COST_BASIS` sets the default). Which one is right is a fact about
  the invoice rather than about this codebase, and the way to find out is to
  put both next to one. Both hour figures stay on every row either way, since
  the gap between them is idle time and that is the lever on the bill.
- **Teammate messages are metered.** `comms_email_sent`, `comms_sms_sent` and
  `comms_sms_received` join the usage-event vocabulary, recorded at the two
  choke points a message already passes through
  (`FountainWeb.TeamCommsMcpController`'s audit callback and
  `Team.Comms.Inbound`). An inbox and a number cost money every month and a
  message costs money each time, and only the first half was visible. Inbound
  counts, because AgentPhone charges to receive. Best-effort by the same
  contract as every other usage event; neither call can fail a send.

- **The SDK publishes itself from CI, with provenance**
  (`.github/workflows/sdk-publish.yml`). `@agentshit/fountain-sdk@0.1.0` reached
  npm from a laptop, authenticated by a long-lived token in a `~/.npmrc`. The
  `Publish SDK` workflow replaces that with npm trusted publishing: npm trades
  the workflow's OIDC identity for a short-lived credential, so the repository
  holds no `NPM_TOKEN`, and each tarball carries an attestation a consumer can
  verify back to the workflow and commit that built it (`npm audit
  signatures`). It fires on an `sdk-v*.*.*` tag — the SDK versions on its own
  clock, because the REST API it wraps is additive — and refuses to run when
  the tag and `package.json` disagree, since npm never allows a version to be
  republished.

- **The TypeScript SDK is ready to publish, and can answer a permission
  request** (`sdk/typescript`). It goes to npm as
  **`@agentshit/fountain-sdk` 0.1.0** — scoped, because the `agentshit` org is
  where Fountain's packages live. The install instructions in `README.md`,
  `docs/sdk.md` and `docs/tour.md` no longer say "build it from a checkout",
  because there is now a package to install.

  With it, the one part of the API the SDK could not drive: an agent whose
  `permission_policy` has an `ask` entry stops before the tool call, and a
  `permission_request` block used to reach a caller as an anonymous block with
  no way to reply. It is now a `{ type: "permission" }` run event carrying the
  request id, the summary and the options the agent offered, and
  `run.answer(requestId, optionId)` (or `resume(id).answer(...)`) sends the
  reply. An `ask` agent driven from a script previously lost every held tool
  call to the server's deny-on-expiry.

- **Five dashboards, for three teams** (`deploy/grafana/`,
  `docs/guides/operate/dashboards.md`). Fountain exported 57 Prometheus series,
  a Tempo trace stream and a PostHog event stream, and shipped one starter
  dashboard against a fraction of the first. Ops, product and finance each get
  one Grafana dashboard, and product and finance each get a PostHog dashboard
  for the questions a time series cannot answer.

  The Grafana JSON ships as ConfigMaps labelled `grafana_dashboard: "1"`
  (`deploy/grafana/kustomization.yaml`, referenced from `k8s/kustomization.yaml`
  rather than from the portable baseline, which must not assume a Grafana). The
  kube-prometheus-stack sidecar watches every namespace, so a deploy delivers
  them and an edit made in the Grafana UI is overwritten by the next one.

  Two traps are documented because both are silent. The funnel, conversation,
  sandbox and Oban gauges are polled from the same database by every replica
  and exported once per pod, so a `sum` reports two replicas as twice the work;
  they use `max`, and the finance dashboard collapses the per-replica duplicate
  before it adds providers together. And a counter that has never fired has no
  series at all, so every panel watching a rare failure ends in `or vector(0)`
  to read 0 rather than *No data*.

- **Fountain speaks AG-UI.** `POST /api/agui/:agent_id` answers the
  [AG-UI](https://github.com/ag-ui-protocol/ag-ui) protocol's `RunAgentInput`
  with its SSE event stream, so any AG-UI host registers a Fountain agent with
  a URL and a bearer token — CopilotKit's
  [OpenBot](https://copilotkit.ai/openbot), where a coworker *is* an AG-UI
  endpoint, is the host it was built against. The host's thread binds to one
  conversation (`agui:<threadId>`), so one channel is one sandbox and the
  agent's memory stays where it lives rather than being replayed as a
  transcript each turn. Tool use and lifecycle stages relay as AG-UI thinking
  events; no AG-UI *tool call* is emitted, because a Fountain agent runs its
  tools in its own sandbox and already has the result. See
  [OpenBot (AG-UI)](https://fountain.inevitable.fyi/docs/integrations/openbot).

- **Usage on the console's dashboard.** A "This month" row — conversations,
  turns, sandbox time, and tokens in/out — on the same calendar the billing
  page uses (`Billing.current_month_range/0`, promoted out of two identical
  private copies so the two pages cannot disagree about which month they
  mean). Usage events are recorded whether or not billing is switched on, so
  a self-hosted console, which has no billing page at all, sees this too.
  Tokens are the tenant's own inference spend and are reported, never
  charged. `Conversations.token_usage/3` sums them in Postgres over the
  period; `conversation_counts/1` and a `limit:` option on
  `list_conversations/2` mean the page no longer loads every conversation an
  account has to render a count and five rows.

- **`Fountain.Apps` — one place that knows where the browser apps live.**
  Conversations and the team roster are standalone single-page apps on the
  API; `CONVERSATIONS_APP_URL` and `TEAM_APP_URL` say where (defaulting to
  the builds hosted at jakegaylor.com, which work against any Fountain that
  admits the origin in `API_CORS_ORIGINS`; `""` means this deployment has no
  such app). `GET /api/catalog` now reports them as `apps`, and the links
  that leave Fountain — a forwarded support report, the Hermes plugin's
  `url` — point at the app rather than at a console route.

- **`first_prompt` on conversation JSON.** `GET /api/conversations` and
  `GET /api/conversations/:id` carry the first turn's prompt, so a client
  can title an untitled conversation the way the web sidebar does without
  a `/turns` call per row. Null until the first turn exists.

- **A teammate with its own email address and phone number** (proof of
  concept, behind the `team_comms` feature flag). `POST
  /api/team/:agent_id/contact` provisions an AgentMail inbox and an
  AgentPhone number under Fountain's own keys and records them on the
  teammate; `DELETE` releases them; `GET /api/team/comms` reports whether
  the caller may. The `/team` page gains a "Give email & phone" button and
  shows the contact. From its next turn the teammate has `email_send`,
  `email_reply`, `email_list`, `email_get`, `sms_send`, `sms_list` and
  `my_contact_info` MCP tools, served by Fountain at `POST
  /api/mcp/team-comms/:conversation_id` with the conversation's own sprite
  token — no provider key ever enters a sandbox. Sends are audited
  (`team.contact.sent`, never the content). Configuration:
  `AGENTMAIL_API_KEY`, `AGENTPHONE_API_KEY` (+ optional base URLs and
  `AGENTMAIL_DOMAIN`). Giving a number also collects `prompt_from_number`
  — your phone: a text from it to the teammate's number arrives as a prompt
  in the teammate's conversation (AgentPhone's master webhook at `POST
  /api/webhooks/agentphone`, HMAC-verified with `AGENTPHONE_WEBHOOK_SECRET`,
  deduplicated by delivery id); texts from anyone else are ignored.
  `PATCH /api/team/:agent_id/contact` (and "change" on `/team`) moves that
  number without buying or releasing anything. The form carries the SMS
  opt-in statement (frequency, rates, STOP/HELP, privacy + terms), and
  `STOP`/`START`/`HELP` from the registered number are honoured in the
  inbound path (`contact.prompt_opted_out_at`).
- **Per-user feature flags** (`Fountain.FeatureFlags`), evaluated by PostHog
  (`POSTHOG_PROJECT_API_KEY`, `POSTHOG_HOST`) with a one-minute per-user
  cache; when PostHog is unreachable the last answer it gave is reused and,
  with none, every flag reads off — an outage never turns a feature on.
  `FEATURE_FLAGS_ON=team_comms` forces a flag on for everyone without
  PostHog.

- **A fresh conversation on the same computer.** `POST
  /api/team/:agent_id/conversations` retires the teammate's current
  conversation (it stays in its history, past resuming) and opens a new one
  on the **same sandbox**: the next message starts a fresh runtime session on
  the same disk — files, clones and installed tools intact — instead of
  provisioning a new computer. Nothing is interrupted (400 `conversation_busy`
  mid-turn; 503 `provisioning` while the computer is starting); when the
  computer is gone a new one is provisioned, as adding does. Audited
  `team.conversation.rotated`; the stream sends `team`. Underneath,
  `ConversationServer.release_conversation/2` ends a conversation without
  touching its sandbox, and terminating or deleting a retired thread no
  longer reaches the sandbox its successor is running on.

- **Runner-backed teammates on the team surface** (#834). Presence tells
  "asleep" from "the machine is off": a teammate on a self-hosted runner whose
  daemon is not connected is `machine_offline` (a message answers `503
  runner_offline` rather than waking it; a scheduled run waits for it). The
  sandbox object carries `provider` and, on a runner, `runner: {id, name,
  hostname, online, path}` — where it runs — and a runner connecting or
  dropping sends a `team` event on `/api/team/stream` and refreshes `/team`.

- **Rename a teammate and list its history over the API** (#831, #832).
  `PATCH /api/team/:agent_id {name}` renames (null/blank → the agent's name;
  audited `team.renamed`; the name carries onto the next fresh conversation),
  `GET /api/team/:agent_id/conversations` lists every conversation the agent
  has had on the team newest first with the live one flagged `current`, and
  `GET /api/conversations` takes `agent_id`, `channel_id` and `status`
  filters.

- **`GET /api/search`** (#826). Full-text search across the caller's
  conversation titles, turn prompts and assistant replies, with `kind`,
  ids and a plain-text snippet per hit; `websearch` syntax, `limit`/`offset`,
  `agent_id`/`conversation_id`/`since`/`kinds` filters. Replies come from a
  new `turns.reply_text`, materialised when a turn ends from the same block
  parse the transcript uses (never tool noise); turns that ended before this
  release are searchable by prompt until
  `Fountain.Release.backfill_turn_replies/0` runs once on the server.

- **Team schedules over the API** (#825). `GET /api/team/schedules`, and
  `GET|POST /api/team/:agent_id/schedules`, `GET|PATCH|DELETE
  /api/team/:agent_id/schedules/:id`, `POST .../:id/run` — the routines the
  team page offers, for standalone clients, wrapping `Fountain.Team.Schedules`
  under the same tenant scoping and audit attribution as the rest of
  `/api/team`. The team stream sends a `schedule` event when a schedule is
  created, updated, deleted or fired, so a client re-lists rather than polls.

- **Token usage per turn and per conversation** (#827). The figure the
  runtime reports on the ACP `session/prompt` response is stored on the turn
  (`turns.usage`: input, output, cache read/write) and summed on the
  conversation (`usage_total`); `GET /api/conversations/:id/turns`,
  conversation objects and `/api/team` roster entries (per teammate, across
  every conversation it has had on the team) carry it. Recorded once per turn,
  never from the live `usage_update`s. Turns before this release have
  `usage: null`.

- **Hermes Agent plugin** (`integrations/hermes/`). Fountain agents as tools
  inside [Hermes Agent](https://github.com/NousResearch/hermes-agent):
  `fountain_agents`, `fountain_run`, `fountain_send`, `fountain_wait`,
  `fountain_status`, `fountain_conversations`, `fountain_terminate`, plus a
  `fountain` skill and a `/fountain` slash command. Delegation over the HTTP
  API — a Hermes turn hands a task to a named Fountain agent, the work runs in
  a Fountain sandbox, the answer comes back as the tool result; multi-turn
  via `fountain_send`, bounded waits with a resumable cursor so a long turn
  never trips Hermes's tool deadline. Reads the log feed as blocks
  (`?blocks=true`), so it never learns a runtime dialect. Stdlib Python, no
  dependencies; credentials resolve like the CLI (`FOUNTAIN_API_KEY`,
  in-sandbox `FOUNTAIN_TOKEN`, `~/.fountain/credentials`). Install with
  `hermes plugins install BinaryBourbon/fountain/integrations/hermes/fountain
  --enable`. Docs: `docs/integrations/hermes.md`; tests run in CI.
- **"Sign in with Fountain" for the browser apps — Fountain as an OAuth 2.0
  authorization server (ADR 0021).** `GET /oauth/authorize` (consent page
  behind the session; a signed-out user logs in — password or GitHub — and
  returns to it), `POST /api/oauth/token` (authorization code + PKCE S256,
  public clients, one `invalid_grant` for every wrong grant, rate-limited)
  and `POST /api/oauth/revoke`. Clients are registered with `OAUTH_CLIENTS`
  (exact redirect URIs); the token is an ordinary 30-day API key named
  `oauth:<client_id>` that lists and revokes under Account → API keys.

- **`GET /api/catalog` and `POST /api/avatars/generate`.** The vocabulary the
  agent and environment forms are built from — runtimes and model
  suggestions per runtime, sandbox providers usable on the instance and the
  default, the package managers provisioning installs, the avatar
  generator's bases and moods — and the generator itself over the API, so
  the standalone conversations app can carry the agents / environments /
  vaults pages without hard-coding any of it (#815).

### Changed

- **Feature status page.** `/docs/reference/feature-status` names the two
  features that are not on for every hosted account, teammate email and
  phone (alpha, `team_comms`) and brokered credentials (limited access,
  `BROKER_TENANTS`), and each page that describes one now opens with a note
  saying so. `api.md` gains the egress and secret-bindings routes.
- **Subscription plans shipped and were retired inside this release**
  (ADR 0026 → ADR 0030/0031; #991, #1036, and the plan, trial, MRR,
  free-contact-allowance and `mix fountain.verify_plans` work that followed).
  None of it is in v0.13.0; what replaced it is under Added ("Credits are
  the product") and Upgrade notes. Self-hosters: with credits off, every
  account gets `SANDBOX_CAP_CEILING` (20) concurrent sandboxes, so nothing
  drops to 2 on upgrade.
- `Billing.provider_spend/1` (the `/admin` and `/admin/sandboxes` hours) and
  `Finance.cost/3` (the money on `/admin/finance`) read one fold,
  `Finance.platform_totals/1`, instead of each summing the attribution rows
  their own way.

- **Billing debt 3/3: the billing page shows what was charged.**
  `usage_summary/3` (billing page, dashboard, `GET /api/account/billing`)
  and the admin table count conversations as the ones that ran a turn in
  the month — from `turn_started` events, which survive a deleted
  conversation and cover a persistent home that provisions nothing — rather
  than as sandbox provisions, and carry `credit_burned_cents`: what the
  ledger actually took for the window, shown as "Spent" beside the metered
  hours. SDK 1.2.0.

- **Credits cleanup 3/3 (#1128).** The prose catches up with ADR 0031. ADR
  0006 is marked superseded, ADR 0030's status block describes what is built
  (no switches, no tiers, `CreditExpirer`), ADR 0026 and 0031 are corrected,
  and the index is regenerated. CLAUDE.md loses the plans trailer and gains
  the `require_pending_verification` hook row. The manual's API page lists
  the endpoints that exist (`credits/checkout`, admin `credits`, `comped=`),
  the 402 and 503 codes, and drops the portal, subscription checkout and
  resync; the configuration, architecture, mail, Sprites, integrations,
  dashboards, SDK and release-task pages, `.env.example`, the compose file,
  the k8s configmap and the finance Grafana board no longer describe a
  subscription, a trial or a plan. Every docstring and comment the review
  found still describing the subscription era is rewritten, including the
  `users` field comments that had drifted onto the wrong fields.

- **`k8s/` is gone; `deploy/` is the only Kubernetes directory** (ADR 0032
  addendum). The manifest artifact now pins the image in
  `deploy/k8s/kustomization.yaml`'s own `images:` block, and
  `FOUNTAIN_BUILD_SHA` is baked into every main-line image as it always was
  for releases. The artifact is generic; the Kubernetes guide shows how to
  track `main` with Flux from it.
- **The hosted instance's Kubernetes overlay left the repo** (ADR 0032).
  `k8s/` held the maintainer's own cluster — CNPG, Infisical, Traefik,
  hostnames, backups, alerts, the rate card, the OAuth client list — as an
  overlay of `deploy/k8s/`, and `publish-manifests.yml` shipped both in the
  manifest artifact. That overlay now lives in the private home-cloud repo,
  applied on top of the artifact with Flux patches. `k8s/` keeps only the
  image pin (`pin.yaml`), so the artifact is the portable baseline plus the
  image built from that tree and nothing else. Self-hosters were never meant
  to apply `k8s/`; the Erlang clustering env it used to demonstrate is now
  written out in the Kubernetes guide. `.sops.yaml` is gone with it.

- **The ACP peer outlives its prompt.** `Fountain.Runtimes.ACP.Peer` no
  longer ends when the prompt is answered: it reports the stop reason and
  waits in `:idle` for the next `prompt/3` on the same connection (no second
  handshake, no `session/resume`, no model pin), reports an autonomous
  cycle's end as `{:cycle_end, kind}` from the adapter's origin-marked
  `usage_update`, and closes on `close/1`. Part 1 of 3 for #817. Nothing
  changes in production yet: `ConversationServer` still stops the peer at
  turn end, until part 3 moves the connection to the wake.

- **A running sandbox is no longer destroyed at 24 hours.** The continuous-run
  ceiling (`SANDBOX_MAX_LIFETIME_HOURS`, ADR 0017) now defaults to `0`, off,
  for every sandbox mode: a tenant who wants a machine running all day is not
  something to stop, and for a persistent home the disk is the product. The
  idle timeout (`SANDBOX_IDLE_TIMEOUT_MINUTES`, still 60) is the only
  automatic stop, and it parks rather than destroys; the plan's
  concurrent-sandbox cap bounds how many machines stay up. An operator who
  wants the old backstop sets the variable, and then an ephemeral sandbox is
  destroyed at the ceiling and a home is parked, exactly as before. #936.

- **Turn hours add up per turn.** With several conversations on one sandbox
  at once, a tenant's turn hours are the sum of their turns (two
  conversations each running an hour on one machine spend two), while the
  sandbox's busy time stays the union of the same intervals — the machine's
  view, which a provider bill relates to. `SandboxUsage` reports both
  (`turn_seconds` beside `busy_seconds`); the billing page, the API usage
  summary and the admin finance panel now read the sum. On a sandbox with
  one conversation the two numbers are equal, so nothing changes for
  today's accounts. ADR 0026 addendum; ADR 0023 step 6.

- **A change that moves a home's identity retires the home.** A persistent
  sandbox is keyed on `(user, agent, environment, vault)`. Moving an agent's
  `environment_id`, deleting an environment, or deleting a vault moved that
  key and left the machine `ready` under an identity nothing looks up — it
  held a concurrency slot and a disk carrying the old environment's or
  vault's secrets. All three now retire the affected homes the way
  `DELETE /api/sandboxes/:id` does: the machine is destroyed, the
  conversations on it are kept and told why (`sandbox`/`reset` with
  `environment_changed`, `environment_deleted` or `vault_deleted`), and the
  next prompt builds a machine on the identity that exists now. Audited as
  `sandbox.reset` with the reason in the metadata. Each request is refused
  with `409 sandbox_mid_turn` (a flash in the console) while a conversation
  on one of those machines runs a turn, and nothing is written.

  Deleting an environment or a vault was additionally broken outright: the
  `ON DELETE SET NULL` on `sandboxes.environment_id` / `sandboxes.vault_id`
  either turned the home into the *no environment* or *no vault* home for
  its identity — so the next launch that asked for neither landed on a disk
  holding the deleted secrets — or collided with
  `sandboxes_home_identity_index` (`NULLS NOT DISTINCT`) and failed the
  delete with an unhandled constraint error. #1084.

- **A sandbox that is gone is gone for every conversation on it.** When a
  prompt wakes a conversation and finds its sandbox has vanished, the fresh
  machine it provisions now takes every live conversation that shared the old
  one along (runtime sessions cleared, a `sandbox`/`replaced` stage event on
  each transcript), instead of leaving them pointing at a terminated row and
  provisioning a machine each on their next prompt. ADR 0023 gate 5.

- **A sandbox several conversations hold is treated as one machine.**
  Three rules that used to be one conversation's to break (ADR 0023, steps
  4 and 5): a turn on an opencode or gemini sandbox is refused with
  `409 sandbox_at_capacity` while another conversation's turn runs there
  (claude and codex run several at once — `Runtimes.ACP.concurrency/1`, and
  the check is made under a per-sandbox lock so two prompts cannot both
  start); terminating a conversation destroys the sprite only when it was
  the last conversation on it; and the idle timeout parks the machine only
  when every conversation on it has been quiet for the bound, at which
  point the other conversations' servers are stopped so their next prompt
  wakes it properly. Scheduled teammate runs treat `sandbox_at_capacity`
  like a busy teammate and retry within their window.

- **A conversation's identity travels with its process, not the sandbox's
  disk.** `FOUNTAIN_TOKEN`, `FOUNTAIN_CONVERSATION_ID` and `TRACEPARENT` are
  no longer written to `/home/sprite/.env`; they reach the agent as
  environment on every spawn, exactly as before from the agent's point of
  view. The runtime's detachable session is now started as
  `env FOUNTAIN_CONVERSATION_ID=<id> <adapter> …`, and a reattach after a
  deploy binds to the session carrying its own conversation's tag rather
  than the head of the sandbox's session list — the prerequisite for several
  conversations sharing one sandbox (ADR 0023, gate 1). A `setup_script`
  that did `source .env` no longer sees the callback token; environment and
  vault values are unaffected. The reattach stage event reports
  `matched_by` (`tag`, or `untagged_head` for a session started before this
  release).

- **The dashboard's usage tile is turn hours, not sandbox time.** "Sandbox
  time" was wall-clock hours a tenant's sandboxes were awake — Fountain's cost
  signal, and nothing a customer buys or is measured on. It went up while they
  slept. The tile now shows turn hours against the plan's included hours, the
  unit `Fountain.Plans` actually denominates an allowance in, and the sandbox
  figure moved into the hint. The whole "this month" section also moves to the
  window Stripe invoices where there is one, so the dashboard and
  `/account/billing` can no longer report different numbers for the same
  period; the heading says which window it is on.
- **`/admin`'s per-user usage column shows turn hours.** Same reasoning, one
  page over: sandbox minutes belong next to the bill Fountain pays, on
  `/admin/finance`. The sandbox total and its per-provider split stay in the
  cell's tooltip.
- `Billing.usage_summary/3` and `usage_summaries/2` both carry `turn_hours`
  now, computed from the attribution pass they already ran. `usage_summary/3`
  makes one pass where it used to make one and would have needed two. No API
  field was renamed or removed.
- **`/` is no longer the same page on every deployment.** The homepage sold a
  product: a hero, a 14-day trial, a monthly price, and a footer calling
  Fountain "managed agent infrastructure". Every self-hosted instance served
  it, to an audience of the operator and their own team, none of whom are
  buying a trial of the thing they already run. `/` now serves a plain front
  door — the instance, a way in, and a link to `/docs` — unless the deployment
  sets `MARKETING_SITE=true`. This is the reasoning `LEGAL_ENTITY` already
  applies one page over (#517): an instance must not serve the upstream
  project's terms, and it has no more business serving the upstream project's
  sales copy. The flag is off by default, so a self-host is right without
  reading this entry. It is deliberately not `BILLING_ENABLED`, which an
  operator running Fountain commercially inside their own company may well
  turn on.
- **A closed instance stops advertising registration.** With
  `REGISTRATION_ENABLED=false` the public pages still linked "Get started" and
  "Register", and `Accounts.registration_allowed?/1` then refused the submit.
  The nav, the footer and the new front door now hide the link. The context
  check is unchanged and is still the control.

- **Fountain is no longer MIT licensed** (ADR 0027). The server under
  `apps/fountain` is now **AGPL-3.0-or-later**, `ee/` is under the **Elastic
  License 2.0**, and `cli/` and `sdk/typescript` are **Apache-2.0**. Releases
  through v0.12.0 were MIT and stay MIT, irrevocably, for anyone who has them.

  The reason is narrow. MIT let a funded competitor take Fountain, improve it,
  host it and return nothing, and the part that stung was not the revenue but
  that nobody else running Fountain got any benefit from that work. AGPL
  section 13 answers exactly that and nothing more. A competitor may still
  host Fountain commercially, in direct competition with the hosted product.
  They must do it in the open.

  Nothing changes for an integrator. The CLI, the TypeScript SDK and the two
  single-page apps are permissive on purpose, because an AGPL SDK would put a
  copyleft obligation on every application that calls the API, which is
  precisely the integration Fountain wants. Nothing changes for a self-hoster
  either: `ee/` is free to run and your changes to it stay private, which is
  what ELv2 grants and what the single-image build requires.

  Contributions come in under the Apache License 2.0 and go out under the
  license of the directory they touch, with a DCO (`git commit -s`), no CLA
  document and no bot. That preserves the ability to sell a commercial
  exception to a company whose policy forbids the AGPL, which would otherwise
  close at the first merged outside pull request. The asymmetry it creates is
  stated in `CONTRIBUTING.md` rather than buried. See `NOTICE`,
  `CONTRIBUTING.md` and `decisions/0027-agpl-relicensing.md`.

- **The console's sidebar shows where you can go.** Account, API keys,
  inference keys, runners, billing, security, the audit log and admin were in
  a popup behind the user's email address; they are sections now. A
  destination you cannot see is one you do not know you have — and the
  conversation list that used to own that space is gone, so there was room.
  What stays at the bottom is what is not a destination: who you are, sign
  out, the theme toggle, and the build version a bug report quotes.

- **Fountain's web UI is a console.** The conversation pages
  (`/conversations`, `/conversations/new`, `/conversations/:id`,
  `/conversations/:id/logs`), the team page (`/team`) and the onboarding
  wizard (`/onboarding`) are gone from the server. Conversations and the team
  are their own apps on the API —
  [fountain-conversations](https://github.com/managoat/demos/tree/main/apps/fountain-conversations)
  and [fountain-team](https://github.com/managoat/demos/tree/main/apps/fountain-team) — and what
  stays here is the operator console: dashboard, agents, environments,
  vaults, audit, API keys, account, admin.
  - The old paths **redirect** (302) to the app that replaced them, or to the
    dashboard where a deployment has no such app. Nothing 404s.
  - Login, OAuth and email verification all land on `/dashboard`, whose
    checklist — an inference credential, an agent, a conversation — replaced
    the wizard. It also stamps `onboarding_completed_at` when the account
    genuinely has those things, which is what the lifecycle funnel's
    "onboarded" stage reads.
  - The sidebar's conversation list, its filters and the preference columns
    behind them are gone, along with the LiveView JS hooks and the d3 CDN
    script only those pages used.
  - The session-authenticated turn-image route went with the chat bubbles
    that used it; the bearer route (`/api/conversations/:id/turns/:id/images/:n`)
    is unchanged.

  **Upgrade notes — self-hosted.** `/conversations` and `/team` now send a
  browser to the hosted apps at `https://jakegaylor.com`. They are static
  builds that take *your* Fountain's URL as input, so they work against your
  server — but only once it admits that origin:

  ```
  API_CORS_ORIGINS=https://jakegaylor.com          # add to what you already set
  ```

  Add `https://jakegaylor.com/fountain-conversations/` and
  `.../fountain-team/` to `OAUTH_CLIENTS` too if you want "Sign in with
  Fountain" rather than pasting an API key. Prefer to host your own copies?
  Point `CONVERSATIONS_APP_URL` / `TEAM_APP_URL` at them. Prefer neither? Set
  both to `""`: the console stops offering them and the old paths land on the
  dashboard instead of sending anyone off-site. Nothing about the API
  changes — a deployment driven by the CLI or `/api` is unaffected either way.

### Fixed

- **Every exit code Fountain ever recorded from Sprites was an invented 0**
  (#994). The pinned `sprites-ex` fork decoded the one-byte exit frame as
  four bytes, so no real exit ever matched and the socket close synthesised
  `0`: a failing setup script reported a healthy sandbox and a `git clone`
  that died produced `clone/done` and an agent with no repository. The real
  code is read now.
- **A warm start from a checkpoint skipped the network policy** (#990). An
  egress policy is a live provider call, not a file on the disk image, so a
  `limited` environment restored from a checkpoint provisioned with no
  egress restriction at all, on every provider. The policy is applied on
  every start.
- **An agent's system prompt never reached the runtime** (#848, #849; wired
  again after a squash-merge dropped the call sites). `agents.system` was
  stored, edited and exported and never read at provision, so every agent
  ran on its CLI's default persona. `Fountain.Runtimes.Instructions` writes
  it, with a provenance header, into the runtime's user-level instructions
  file on provision and reattach, and a wiring test fails if either stops.
- **A claude agent's MCP servers now start** (#837, #838).
  `claude-agent-acp` ignores the `mcpServers` passed on `session/new`
  (agentclientprotocol/claude-agent-acp#883), so no claude agent's MCP
  servers reached the model on any provider. Fountain provisions them as a
  project `.mcp.json` plus `enableAllProjectMcpServers` in
  `~/.claude/settings.json` instead.
- **Model suggestions the providers had retired** (#978, #993).
  `gemini-2.5-pro` / `gemini-2.5-flash` (404, "no longer available to new
  users") give way to `gemini-3.1-pro-preview` and the 3.x flashes;
  `gpt-5-codex`, both the suggestion and the codex form placeholder, is
  retired for `gpt-5.3-codex`; `claude-opus-4-7` is listed. Every id was
  verified by calling it.
- **A refused model is named in the turn's error** (#992). The peer reads
  the refusal out of the provider's sentence and fails the turn as
  `model_unavailable` with the requested id, instead of an inspected
  `{:acp_error, ...}` tuple; the `model` stage event carries the id.
- **opencode is pinned by its canonical `provider/model` id** (#1157). Sent
  the bare id, opencode said "model not found" and silently fell back to its
  own default over its own gateway, so the configured provider was never
  called.
- **A backend that cannot enforce a `limited` environment is refused up
  front, by name** (#987). A runner has no egress policy; pairing one with a
  `limited` environment used to fail several steps into provisioning with a
  transport-shaped reason, and is now refused before a sandbox is created,
  with the console form saying which provider cannot.
- **Channel resume skips a conversation whose sandbox is gone** (#985). A
  `channel_id` bound to an `idle` conversation on a `terminated` or `failed`
  sandbox opens a new conversation instead of resuming a cold agent inside a
  transcript that reads as continuous; `suspended` stays resumable.
- **Fifty `reattach started` events per restart** (#971, #977). Cluster
  convergence re-entered reattach from the top and announced itself before
  touching the sprite; the event is published once the sprite answers.
- **A lost wake race on a reused sandbox dropped the prompt** (#667, #786).
  The reuse arm now hands the prompt to the server that won, as the
  fresh-sandbox arm already did.
- **The team stream flushes a first byte immediately** (#810, #812), so an
  ingress that buffers chunked responses (Cloudflare) no longer shows
  "reconnecting" for the 15 s until the first heartbeat.
- **A teammate on a ready sandbox with no turn yet is `online`**, not
  "starting computer" (#839).
- **Team comms hardening** (#853, #854, #858): an AgentPhone persona per
  number, voice calls answered with a spoken decline, provider refusals
  reported as 424 with the provider's reason, and a from-line stating the
  trust boundary.
- **The SDK no longer sets `User-Agent` in a browser** (#1062, SDK 0.1.5).
  Firefox sends it and so turned every call into a CORS preflight the
  allow-list refused; the CORS plug also allows the header for older builds.
- **A best-effort write no longer takes the request down** (#1045).
  `last_used_at` stamps and password-reset delivery ran in a linked
  `Task.async`, so a connection blip on a column nothing reads could kill an
  already-authenticated API call; they are supervised and unlinked now.
- **The marketing page** (#951, #1024, #1027, #1107; renders only with
  `MARKETING_SITE=true`): invented testimonials and a "first conversation in
  under five minutes" figure are removed; the cap is described as refusing
  the next sandbox, not queueing it; parked, idle and self-hosted time is
  stated to cost nothing; the pricing section says what a credit buys in the
  meter's own numbers.
- **`/llms.txt` points at `/docs`** (#1013), not the authenticated `/help`
  routes that rendered a login page to every agent following the index.
- **Broker, three findings from wiring the workbench to gate 4.**
  `GET /api/conversations/:id/egress` needs full scope, like
  `/api/secret-bindings`: a sandbox's sprite-scoped token could read the
  request log — which secrets went to which host — for any conversation on
  the tenant (#1152). Its 502 no longer leaks an inspected Elixir term as
  `message`; the client gets "The egress broker did not answer." plus a
  stable `reason` word (`econnrefused`, `api_error_503`, ...) and the detail
  goes to the server log (#1153). The OpenAPI description of
  `networking_config` says where `limited` is enforced (the broker on a
  brokered account, the sandbox otherwise) instead of the pre-gate-2 sandbox
  story, and `GET /api/auth/me` carries a read-only `brokered` so a client
  can label the mode without probing `/api/secret-bindings` (#1154).

- A brokered sandbox lets `sudo` keep the proxy variables (a sudoers `env_keep` drop-in, installed beside the broker CA), so a setup script's `sudo apt-get install` reaches a mirror. Before, sudo's `env_reset` stripped `http_proxy`, apt resolved the mirror directly and the broker floor refused it with `Temporary failure resolving`; the first brokered provisions of real environments failed there. (#1158)

- **Billing debt 1/3: the month is half-open, one gate, one cap rule.**
  `Billing.month_range/2` replaces four hand-rolled month windows; its `end`
  is the first instant of the next month, so the last second of every month
  is no longer dropped from every usage query (`GET /api/account/billing`'s
  `period.end` moves accordingly; SDK 1.1.1). `Credits.Rent` runs through
  `Credits.check_balance/2` (`min:` a month's rent) instead of its own
  balance read, so an expired-but-unswept grant funds a contact no more than
  it funds a turn. Under the reservation lock the credit gate now runs
  before the sandbox quota, so an unfunded account's cap is 0 everywhere
  (`sandbox_limit/1` and `sandbox_limit_for/1` agree) and it is refused as
  `insufficient_credits`, never as a 0/0 quota. `Credits.gate/1` is
  `check_balance/2`; `Credits.active?/0` is gone (it was `Billing.enabled?/0`).
  `Finance.deferred_cents/0` is the one deferred-balance query.

- **Credits cleanup 1/3 (#1126).** Six ledger bugs left by ADR 0031 and the
  customer-facing text that still described subscriptions. An expiry now
  takes only what its own grant still holds, read inside the ledger's
  transaction, so a burn racing the sweep can no longer make it reach into
  purchased money; a debit that names a lot never falls through to another.
  A charge disputed and then refunded is clawed back once. An expired grant
  stops funding new work the moment it passes (`check_balance/1` subtracts
  expired-but-unswept lots) and the pricer's ten-minute tick runs the expiry
  sweep. `Rent.charge/3` checks idempotency before the balance, so a re-charge
  of a paid month on a short balance no longer starts a release clock. The
  ledger lists and indexes open lots by `seq` (migration). The billing page,
  the credit emails, the dashboard hint, the terms, privacy and home pages,
  the quota and contact-limit messages and a scheduled run's error no longer
  mention plans, trials or subscriptions; `credit.*` audit events refresh
  PostHog person properties. `/admin/users` and `GET /api/admin/users` take
  `comped=` in place of the silent no-op `status=` filter and `trial_end`
  sort. SDK 1.0.1 names `insufficient_credits` and `fleet_full`.

- **A background task the agent starts survives the turn that started it.**
  Fountain closed the runtime connection at every `end_turn`, and the adapter
  treats that connection as the session, so a `Monitor`, a `run_in_background`
  shell or a `ScheduleWakeup` that Claude Code left running was killed the
  moment the turn ended, and codex's "Allow for Session" grant was thrown away
  before the next turn. The connection now lives for the sandbox wake, not one
  turn: after a turn it waits idle for the next prompt on the same session — no
  second handshake, no `session/resume` — and closes only when the sandbox
  stops being the conversation's (idle park, ceiling, terminate, release,
  shutdown). A follow-up the agent narrates after its turn ends lands on the
  transcript as an `autonomous` turn. Across a deploy a follow-up in flight is
  still lost, and its orphaned adapter session is reaped by the conversation's
  tag so a co-tenant on a shared sandbox is untouched. ADR 0014, #817.

- **A conversation's title was the model refusing its first prompt.** The
  title generator handed the first prompt to a chat model with one line of
  framing, so a prompt shaped like an instruction ("Run exactly this shell
  command...") got answered rather than named, and "I can't execute shell
  commands or access your system" became the conversation's title in the
  sidebar, on the team page and in `GET /api/sandboxes` (#1074). The model
  is now told it is naming a conversation it is not party to, and a reply
  that opens in the first person, apologises or hedges is thrown away in
  favour of the prompt's own first line.

- **Deleting an agent that had a versioned conversation failed.** The
  delete cascades to the agent's versions, and Postgres re-checked the
  conversation's `agent_version_id` mid-cascade, before its own SET NULL
  ran, so every agent with a conversation started since config versioning
  (#1049) refused to delete with a foreign-key error. The conversations are
  unpinned from their versions first now; the version was provenance only.

- **A conversation interrupted mid-provision now rebuilds its sandbox instead of failing in `clone`.** A deploy or a Horde rebalance that killed a server during provisioning restarted it against the same half-built sprite, where `git clone` refused the existing checkout and the whole conversation failed. The restart now discards the remnant and provisions clean; the `provision started` event says so.

- **The finance panel reported teammate-contact revenue nobody was charged.**
  It priced every non-comped contact at `Plans.contact_monthly_cents/0`, which
  returns $5 whether or not anything is configured to charge it. The actual
  billing path, `sync_contact_addon/1`, has four guards in front of that
  arithmetic — billing off, **no `STRIPE_PRICE_ID_CONTACT` on this
  deployment**, a comped account, or an account with no Stripe subscription to
  hang an item on — and any one of them means the invoice says zero.

  The panel copied only the last step, and a comment claimed the two "cannot
  disagree". They disagreed for every deployment that had not set the contact
  price, which is the state a deployment stays in on purpose: setting that
  variable puts a line item on the next invoice of every tenant already
  holding contacts (#991). `/admin`'s MRR tile inherited the same error
  through `Finance.mrr/0`.

  Contact revenue is now what the add-on would actually bill. Where nothing
  bills for contacts the panel says so out loud rather than showing a bare
  `$0.00` beside a cost section still counting real inboxes and numbers —
  which is the true and useful shape of it: those contacts cost money and earn
  none.

- **ADR 0028 said a PostHog event definition is permanent. It is not.** The
  claim came from ADR 0025 and was repeated without checking. Trying to act on
  it is what disproved it: the nine request-line definitions `api.request`
  retired stopped receiving events on 2026-08-22, and about a day later they
  were gone from the project's taxonomy — a full listing returns 32
  definitions with no request line among them, `?search=POST` returns zero,
  and `?include_hidden=true` returns the same 32. The historical events remain
  queryable; only the taxonomy entries went. The decision does not change and
  neither does `product_event?/2` — 73 new names a day is still a taxonomy
  nobody can read — but the cost is paid while those names exist rather than
  forever, which is a weaker argument for the same conclusion. Corrected in
  ADR 0028's new Correction section, in ADR 0025, in the `Fountain.Analytics`
  and `FountainWeb.Plugs.Audit` docstrings, and in the configuration guide.

- **`/admin/finance` 500'd as soon as a rate card was configured.** #1029 made
  rates fractional; `money/1` still matched only integers, and `rate_label/2`
  passed it the raw rate. The page raised `FunctionClauseError` on
  `money(5.45)` for every visit. It was invisible in CI because every test
  used whole-number rates, and the one test that did use a fractional rate
  exercised the arithmetic rather than the render — no test had ever rendered
  the provider card with a rate set at all.

  A rate is now shown in cents keeping its fraction (`10.76c/hour`), because
  it is a rate and not a total: rounded to whole cents, 10.76 and 5.45 stop
  being comparable and anything between 4.5 and 5.5 reads the same. `money/1`
  also rounds a float rather than raising — every cost path already rounds
  before display, but a cent of rounding is a better answer than a dead page.

- **Analytics no longer geolocates every person to the datacentre.**
  `Fountain.Analytics` sent `"$ip" => nil` believing that meant "no location".
  It does not: PostHog fills a missing `$ip` from the address the batch
  arrived from, which for a server-side sink is a pod's egress address, and
  then geolocates that — all 108 pageviews in the project reported a single
  city. A capture with no client address now sets `$geoip_disable`, and the
  console pageview hook forwards the address `Audited.put_client_ip/1` already
  resolved at mount, under the same trusted-proxy rule the rate limiter uses.
- **The CSP is built at runtime.** It is assembled per response rather than
  baked into a module attribute, because `POSTHOG_HOST` is read in
  `config/runtime.exs` — a compile-time policy would have carried whatever the
  *build* saw (for a release, nothing) and blocked every self-hosted PostHog
  behind a header that looked correct in the source.

- **`admin.plan.changed` and `admin.comped_contacts.changed` are in
  `AdminEvent`'s allowlist.** The list is closed and `record_admin/1` is
  best-effort, so a missing type is dropped silently and the action ships with
  no privilege trail. That has now bitten three times; the new admin tests
  assert the trail rather than only the effect.

- **Product analytics in PostHog** (ADR 0025). Fountain has kept an audit
  trail, a billing meter and a set of OTel spans for a while, and none of them
  could say whether the accounts that verified last week came back. It now
  captures product events server-side into the same PostHog project that
  already evaluates feature flags, so retention, funnels and cohorts stop
  being SQL nobody has written yet.

  The events come from choke points the code already had, never from
  instrumented call sites: `Audit.record/1` (every audited mutation, under its
  own action name), `Billing.record_usage/5` (`usage.turn_started` and the
  other five metering events) and `Conversations.publish_stage/4` (how a turn
  ended). Adding an instrumented action means auditing it, which the guardrail
  test already forces. Console pageviews come from the LiveView auth hook, so
  the console still loads no third-party script, and reading a flag captures
  `$feature_flag_called` while stamping `$feature/<key>` onto every other
  event.

  The trail is a superset of the product stream, and two things it carries are
  refused: the `:api` pipeline's request-log row, whose name holds a resource
  id and would make a new PostHog event type per resource, and an API key
  Fountain issued to itself (a sandbox credential, a Buzz harness credential,
  an OAuth token). Those were 70% of the trail in its first day. A key a
  person mints in the console or through the API is kept. Nothing is dropped
  from the audit trail itself.

  Nothing is sent without `POSTHOG_PROJECT_API_KEY`, and `POSTHOG_CAPTURE=false`
  keeps flag evaluation while stopping capture. Events carry action names,
  resource types, counts and sizes, never secret values, prompts or agent
  output. `POSTHOG_PERSON_PII=false` drops the account email and leaves the
  user id. Delivery is best-effort and bounded: events batch through one
  process, a full queue or a failed request drops them, and each drop is
  counted on `[:fountain, :analytics, :dropped]` so silence and health stay
  distinguishable.

- **Webhooks** (#700, ADR 0024). Until now the only way to learn that
  something happened to a conversation was to hold an HTTP connection open,
  which is a daemon every integrator had to write and a thing a GitHub Action,
  a Lambda or a cron script cannot do at all. Fountain now POSTs conversation
  lifecycle transitions to a URL you own, signed with an HMAC secret, retried
  for about a day, with every attempt visible and redeliverable from
  `/account/webhooks`, `/api/webhooks` and `fountain webhooks`.

  Dispatch hangs off `publish_stage/4`, the same chokepoint the Prometheus
  stage counter is built on, so a new lifecycle outcome cannot be added
  without subscribers seeing it. A test reads the call sites out of the source
  to keep that true. Conversation output stays on SSE: a chatty turn writes
  thousands of chunks and none of them becomes an HTTP request.

  The payload carries ids, a stage and a duration, and never conversation
  content, on the same rule the audit trail runs on. The URL is checked for
  shape when you save it, resolved and checked again before every request, and
  then connected to by the address that was checked, with your hostname in the
  `Host` header and TLS SNI. Redirects are never followed. See
  [Webhooks](https://fountain.inevitable.fyi/docs/reference/webhooks).

- **Sandbox spend attribution: which tenant, on which provider, ran how long.**
  Fountain pays Sprites, E2B and Daytona by the second and had no way to say
  whose seconds those were. `Fountain.Billing.SandboxUsage` now computes active
  sandbox time per `{user, provider}` from the sandbox rows themselves, clipped
  to the period asked about, with parked time subtracted. A **Sandbox spend by
  provider** panel on `/admin` reports hours, sandboxes and tenants per
  provider, names the accounts behind the total, and marks self-hosted runner
  hours as the tenant's own hardware rather than our bill. Every total also
  splits into **busy and idle** — busy being the union of the sandbox's turn
  intervals, so two conversations prompting one sandbox at once count once —
  because a sandbox nobody is prompting is charged at full rate and is the
  part of the bill a shorter idle timeout (decisions/0017) actually removes.
  An hours figure that cannot separate work from waiting says nothing about
  whether the bill is avoidable. Each account sees
  its own split on `/account/billing` and in `usage.sandbox_minutes_by_provider`
  on `GET /api/account/billing`, and Prometheus gained
  `fountain_sandboxes_by_provider_count` for the live view. Deliberately no
  money anywhere: prices are per-provider and per-machine-size, and a made-up
  rate would look authoritative. Documented in
  `docs/guides/operate/sandbox-spend.md`. Closes the metering-correctness half
  of #798.

- **What we need from a sandbox platform** (`docs/integrations/platform-requirements.md`):
  the ten things Fountain had to build itself because no backend promised them,
  each with the workaround it costs us and an acceptance test a platform team can
  run. Written for vendors rather than adapter authors, alongside a dated matrix
  of where all four backends stand today.

- **The SDK's surface, rebuilt from what the applications actually use.** The
  eleven apps on the Fountain API each hand-wrote a client (2,644 lines
  between them), and counting their methods says plainly what belongs in an
  SDK: `markRead`, `listTurns`, a paged event drain and `createAgent` appear in
  all eleven, and `/api/team` in ten. So the SDK gained `fountain.team`
  (roster, `message()` returning a `Run`, history, fresh threads, routines and
  the one-connection team stream), `conversation.markRead()`,
  `conversation.history()`, `fountain.catalog()`, `fountain.search()` and
  `fountain.events()`.

- **A guided tour** (`docs/tour.md`): an agent that clones a repository, opens
  a pull request, and then amends the same PR on a follow-up turn thirteen
  seconds later because the sandbox is still up. Every number and output on the
  page came from running it; `sdk/typescript/examples/pull-request.ts` is the
  same thing runnable.

  Errors are now keyed on the server's `error` code rather than the status,
  because that is how every app branches: `ConversationBusyError` (a 400),
  `QuotaExceededError` (a 429, carrying `activeSandboxes`/`limit`),
  `NotReadyError` (a 503, carrying the server's `Retry-After`), plus
  `fieldErrors` on 422 and a `retryable` flag on all of them.

  The SDK also works in a browser now, which those apps all are: no module
  reachable from the default entry imports a Node built-in, and the
  credentials-file reader moved behind the `node` export condition. CI bundles
  the entry for a browser to keep it that way.

- **The SDK's types are generated from the OpenAPI spec.**
  `sdk/typescript/src/generated/openapi.ts` comes from
  `mix openapi.spec.json`; CI regenerates it and fails on a diff, so a schema
  change in Elixir cannot leave the SDK describing an API that no longer
  exists. Generating it immediately found one: see below.

- **The E2B template and the Daytona snapshot are rebuilt by CI** (#692). Both
  were hand-built artifacts from one afternoon in August, and nothing rebuilt
  them when `images/` changed or refreshed the four agent CLIs baked into
  them. A stale sandbox image does not announce itself: every conversation
  pinned to that provider quietly runs a months-old `claude`, `codex`,
  `gemini` or `opencode`. The new `Sandbox images` workflow rebuilds both on a
  change to `images/`, once a week for the CLI versions, and on dispatch.

  Each rebuild is smoke-tested in a real sandbox against
  `scripts/sandbox-image/smoke.sh`, which is one file both providers ship
  in-guest so they are held to the same contract. It does the global npm
  install rather than reading the prefix setting, because #691's failure mode
  was exit 243 with no output and the setting looked right. Pull requests run
  the same Dockerfiles through `docker build` and the same smoke, with no
  provider account involved — which is also what stands between an upstream
  apt or npm break and the minutes when the Daytona snapshot name, which
  cannot be rebuilt in place, does not exist.

- **`fountain.me()` returned `null` against a real Fountain**
  (`sdk/typescript`). `GET /api/auth/me` is one of the nine endpoints that
  answers with the object itself instead of `{data: …}`, and the SDK unwrapped
  it anyway, so the call documented as "the cheapest way to check a key works"
  handed back `null` on success. The test suite was green because the in-process
  fake wrapped the response too, and the only test touching the path used the
  raw `request()` escape hatch rather than the verb. The fake now answers
  unenveloped, `me()` is tested through `me()`, and `test/server.ts` carries the
  list of unenveloped endpoints so the next route added there is checked against
  the real envelope.

- **An opencode or gemini agent ignored its system prompt.** Both runtimes run
  with `HOME=/tmp` — a workaround for a rename that fails across
  `/home/sprite`'s ACL boundary — and their skills were written there
  correctly. The system prompt was not: it went to
  `/home/sprite/.config/opencode/AGENTS.md` and `/home/sprite/.gemini/GEMINI.md`,
  which neither CLI reads. Every agent on
  those two runtimes ran on its CLI's default persona, with nothing in the log
  to say so, and the test asserted the same wrong paths. Both the `HOME` export
  and the paths written under it now come from one table
  (`Fountain.Runtimes.Layout`), so they cannot disagree, and a guardrail test
  checks the agreement rather than the literals. claude and codex were never
  affected.

- **A sandbox that failed never recorded when it stopped.** Of the dozen
  writers of a terminal sandbox status, the ones that terminated passed a
  `terminated_at` and the ones that failed never did, so a failed sandbox
  carried a null end for the rest of its life. `Conversations.update_sandbox/2`
  now stamps the column at the same choke point that meters the transition, and
  a migration repairs the backlog from `updated_at`. Without it, spend
  attribution reads every historical failure as a sandbox that is still
  running.

- **Sandbox minutes only appeared when a sandbox died, and then all at once.**
  The whole lifetime landed in whichever period the teardown happened to fall
  in, so a long-lived agent reported zero for months and then a spike, a
  sandbox spanning a month boundary billed entirely to the later month, and one
  still running reported nothing at all. `usage_summary/3` and
  `usage_summaries/2` now report the time that actually ran inside the period
  asked about. `/account/billing` and the admin usage column change with them.

- **Every line of every code block in `/docs` and `/help` had a light box
  painted behind it.** Tailwind Typography's `code` variant matches the
  `<code>` inside a `<pre>` as well as inline code, so the inline-code chip —
  pale background, padding, rounded corners — was applied line by line inside
  the dark code blocks. The chip is now scoped to inline code. While there:
  fenced code is syntax highlighted (Lumis, `github_dark_high_contrast`,
  whose background matches the console's `--color-code-bg`), as it already was
  on the published MkDocs site, and admonitions — which arrive as blockquotes —
  no longer render in italics wrapped in typographic quote marks. The
  highlighter's tree-sitter parsers are baked into the image at build time:
  it otherwise fetches them from a CDN on first use and caches them on disk,
  and the deployment has neither the egress nor a writable filesystem, so a
  self-hosted instance would render every fence plain.

- **`Repository` declared neither `secret_key` nor `ref`.**
  `Provisioning.clone_https/4` reads both — `secret_key` names the secret the
  clone authenticates with, `ref` picks a branch — so a private repository
  could not be expressed by a client generated from the spec. Without
  `secret_key` the clone fails *inside the sandbox*: provisioning continues,
  and the agent opens on an empty directory.

- **`AgentRequest` did not declare `allowed_environment_ids`.** `AgentUpdate`
  declared it and `Agent.changeset/2` has cast it since the allowlist shipped,
  so `POST /api/agents` accepted the field while the spec said it did not — a
  client generated from the spec could set the allowlist on `PATCH` and not on
  `POST`.

- **A TypeScript SDK** (`sdk/typescript`; not yet published to npm). Running
  an agent is one call — `fountain.run(prompt, { agent, vault, environment })` —
  which opens a conversation, follows the turn and hands back the answer, the
  tools used and a URL a human can watch. The handle it returns can be awaited,
  iterated for lifecycle events, or read as a text stream; `resume(id).send(...)`
  continues in the same sandbox. Every integration that has ever talked to
  Fountain wrote this wrapper first (the Hermes plugin, `fountain run`, the
  bundled skill); this is that wrapper, once, with the turn-following rules and
  the mid-turn reconnect in one place. Zero runtime dependencies, Node 20.19+.
  Documented at `docs/sdk.md`.

  The SDK also defines what it runs: `fountain.agents`, `fountain.environments`
  and `fountain.vaults` each have `list`/`get`/`create`/`update`/`delete` taking
  a name or an id, and the two latter carry `secrets.set`/`setAll`/`list`/
  `delete`. `AgentInput` is the whole agent definition as one type — runtime,
  model, system prompt, skills, MCP servers, sandbox provider and the two
  allowlists — so `docs/sdk.md` can show a complete definition on one screen
  instead of describing it. Payloads keep the API's own key names, so one
  definition reads identically in the SDK, the REST API and a `fountain.yml`.

- **The dashboard's token total counted only fresh input.** A coding agent
  re-reads its context every turn, so nearly everything it consumes arrives
  as a cached read: a month of real work on the hosted instance was 1.5k
  `input` against 41M `cache_read`. The tile said "1.5k in" for 44M tokens.
  `Conversations.token_usage/3` now reports all four keys the runtimes send
  and `total_input/1` sums the three that went into the model; the tile shows
  that, and names the split on hover.

- **A runtime reporting a malformed usage figure no longer breaks recording
  it.** `turns.usage` is stored as the runtime sent it, but the conversation
  counters it increments are bigints: a string or an object where a number
  was expected raised inside the transaction. Anything that is not a
  non-negative integer now counts as nothing, which is what an unreported
  figure already counted as. Found while building the dashboard's token
  total, which guards the same shape on the way out.

- **The environment form offers only the package managers provisioning
  installs (`apt`, `npm`).** pip, cargo, gem and go were offered, stored and
  never installed; an environment that already carries one of those keys
  still shows it (#815).

- **Blocks over the API, and every conversation on one stream.**
  `?blocks=true` on `GET /api/conversations/:id/events`, on its `/stream`
  and on the new `GET /api/events/stream` adds `blocks` to each event — its
  `data` parsed server-side into the text / thinking / tool_use /
  tool_result / init / result / error / raw blocks a transcript renders,
  the same parse the web UI uses (`Fountain.Conversations.Blocks`, with
  `LegacyBlocks` moved out of the LiveView into `Fountain.Runtimes`), so a
  client on another origin never re-implements a runtime's dialect (ADR
  0014 applied to the wire). `GET /api/events/stream` carries every
  unfinished conversation of the caller on one SSE connection, labelled with
  `conversation_id`, plus a debounced `conversations` event when the list
  changes. Groundwork for the standalone conversation UI (#813).

- **The team over the API: `/api/team`, plus one SSE stream for the whole
  team and opt-in CORS.** `GET /api/team` (roster with name, presence,
  unread, preview), `POST /api/team` (add, with name/environment/vault),
  `GET`/`DELETE /api/team/:agent_id`, `POST /api/team/:agent_id/messages`
  and `GET /api/team/stream` — every teammate's events on one connection,
  labelled with `conversation_id`/`agent_id`, plus a `team` event when the
  roster changes so the client re-lists. Each route wraps `Fountain.Team`,
  so a standalone client gets the `/team` page's exact semantics (idempotent
  add, wake-or-replace on message, terminate-and-unbind on remove) rather
  than rebuilding them over `/api/conversations`. Presence and the roster
  preview moved into `FountainWeb.TeamPresenter`, shared by the page and the
  JSON. `API_CORS_ORIGINS` (off by default) lets a browser client on another
  origin call `/api` with a bearer key; cookies never cross origins.

- **Team page: name a teammate, pick its environment and vault when adding
  it.** The add dialog is a small form now — agent, an optional name, the
  environment its computer is set up from (the agent's own by default) and
  an optional vault — instead of a bare list with Add buttons. Nothing new
  is stored: the name is the conversation's `title`, the other two are the
  per-launch environment override and `vault_id` every conversation already
  has, so `Team.add_teammate/4` takes them as attrs and the pickers only
  offer what the agent's allowlists permit. A named teammate shows its name
  in the roster, the thread header, the composer and the tab title, with
  the agent's name beside it; a fresh conversation opened when the old one
  is past resuming inherits all three, so a teammate keeps its identity when
  its computer is replaced. `POST /api/conversations` accepts `title` too.
- **Team schedules: a cron that runs a teammate with a prompt.** "Schedules"
  in a `/team` thread header: a cron expression (UTC), a prompt, and where
  it runs. By default the prompt goes into the teammate's own conversation
  as a message from you; **Run in a one-off computer** opens a fresh
  conversation on a new sandbox per run — same agent, environment and vault
  as the teammate — and leaves the thread alone. Pause/resume, edit, "Run
  now", delete; the row shows the next run, the last run (linked) and the
  last error. Removing the teammate deletes its schedules. Under the hood a
  `team_schedules` table (`Fountain.Team.Schedules`), a minute tick
  (`Fountain.Workers.TeamScheduler`, Oban Cron) that claims what is due
  with a compare-and-swap on `next_run_at` and enqueues one
  `Fountain.Workers.TeamScheduleRun` per firing (new `schedules` queue; a
  busy teammate is snoozed for up to 30 minutes). Audited as
  `team.schedule.created` / `.updated` / `.deleted` / `.fired`, runs as
  `system:team_scheduler`.

- **Team page (`/team`): your agents as teammates, one conversation each,
  laid out like a messaging app.** The roster on the left, the selected
  teammate's thread on the right, Enter to send. Adding an agent to the team
  opens its one persistent conversation — which provisions the agent its own
  sandbox, its computer — bound to the reserved channel `fountain:team`
  exactly the way a Buzz channel binds one (`Fountain.Team`; a teammate is a
  conversation, not a new kind of thing). A message is a turn on it; a parked
  or reaped sandbox wakes on the next message as before, and a terminated one
  is replaced by a fresh conversation under the same binding, so the teammate
  is always reachable. Removing a teammate terminates the live conversation
  and unbinds every conversation the agent had under the channel; the rows
  stay in `/conversations`. Audited as `team.member.added` / `.removed`.
  The chat bubbles moved out of `ConversationsLive.Show` into
  `ConversationsLive.Chat` so both surfaces render a turn the same way.

- **Docs: a [`fountain acp` reference](https://fountain.inevitable.fyi/docs/integrations/acp)
  and an "Operating a hosted agent" section on the Buzz page.** The three ACP
  clients (editors, OpenClaw, Buzz) now point at one page for the adapter's
  protocol surface, `_meta` extensions (`channelId`, `freshSession`), what
  streams back and what is ignored. The Buzz page gains the day-2 material:
  who may talk to an agent and how to change it, how other people's clients
  discover it (the kind:10100 entry), what a re-deploy restarts, the owner
  control commands, where to look, and a symptom table.

- **`fountain buzz agents set-access` / `PATCH /api/buzz/agents/:id`.** Change
  who may `@`-mention a hosted Buzz agent (`--respond-to owner-only | allowlist
  | anyone | nobody`, `--allowlist <hex,…>`) after it is deployed; the harness
  restarts with the new gate. The Buzz desktop refuses to change access on a
  provider agent it has already deployed, so without this the only way to open
  an agent up was a re-create under a new key. `fountain buzz agents list`
  shows the current gate per agent. A later desktop deploy still sends the
  desktop's record as the whole truth. (#790)

- **`!rotate` from a Buzz channel opens a new conversation.** The channel-bound
  resume (#774) meant a rotated harness's next `session/new` landed straight
  back on the same conversation, so rotation did nothing on a hosted agent.
  The harness now sends `_meta.freshSession: true` on that one `session/new`
  (block/buzz#6103); `fountain acp` forwards it as `fresh: true` on
  `POST /api/conversations`, which unbinds the current conversation from the
  channel (it keeps running and is retired like any other idle one) and opens
  a new one as the binding. `fresh` is documented in the OpenAPI schema and
  ignored without `channel_id`.

- **A Claude OAuth token the org disallows now falls back to the Anthropic
  API key instead of failing every turn (#655).** `Fountain.Runtimes.Claude`
  picks the OAuth token over the API key when both are on file — it bills a
  subscription instead of metered usage — but an org that disables Claude
  Code's subscription access rejected every turn with no way out short of a
  human noticing and swapping credentials by hand, even though a working API
  key sat in the same row. The ACP peer now recognizes Claude's
  `oauth_org_not_allowed` error kind on the `session/prompt` call
  specifically (session setup failing the same way is a different problem),
  and `ConversationServer` swaps the OAuth token for the API key in the
  running server's env for the rest of the conversation — the failed turn
  says so plainly, and the next prompt succeeds without editing anything. A
  fresh conversation still tries OAuth first, so a policy that later reverts
  self-heals instead of staying pinned to a credential this fix disabled.

- **Team page: a teammate stayed named after its agent, not its first
  message.** The first turn's auto-generated conversation title (a summary
  like "Elixir Tic Tac Toe Game Development") is what #807 shows as the
  teammate's name when one was given — and it was being generated over team
  conversations too, so every teammate got renamed after its first message.
  Title generation now skips team-bound conversations (their title is only
  ever the given name), and a migration clears the summaries already
  stamped on them, so the roster shows the agent's name again.

- **A transient sandbox-provider error no longer retires a live sandbox.**
  Both places that probe a sprite before reusing it — the reattach a
  `ConversationServer` runs when it starts against a `ready` row, and the
  wake path's probe — now give the sandbox up only on a definitive
  not-found. Anything else (DNS, timeouts, 5xx, a credential problem) leaves
  the row exactly as it was: reattach stops and the next prompt tries again;
  a wake answers `503 sandbox_probe_failed` with `Retry-After`. On 2026-08-18
  a 70-second cluster DNS outage during a Horde failover ran reattach for
  nine live sandboxes at once, every probe answered `nxdomain`, and all nine
  rows were marked `failed` — which is exactly what the reaper's destroy
  pass keys on; one of them held a completed turn and a live ACP session.
  The `reattach failed` stage event now carries `retryable`. (#799)

- **A conversation whose sandbox is gone works again on the next prompt.**
  When a wake provisions a fresh sandbox — the old one hit the 24 h ceiling,
  or was retired as failed — the server now clears `runtime_session_id` and
  publishes a `session` stage event (`event: reset, reason: fresh_sandbox`),
  so the next turn is `session/new` on the new disk. It used to keep the old
  id and run `session/resume` against a disk that had never seen the
  session, which failed `-32002 Resource not found` on that prompt and on
  every prompt after it, until the conversation was terminated. The agent's
  in-context memory is still lost when its sandbox is — that has not
  changed — but the conversation, its transcript and its title carry over,
  and the transcript says why the agent does not remember. (#778)

- **A conversation's first prompt no longer races its own creation into a
  second sandbox.** `session/new` (`POST /api/conversations`) starts the
  server through Horde, which may place it on another pod; the first prompt
  arrives ~30 ms later, and if it lands on a pod whose registry has not yet
  synced it saw a `pending` sandbox, missed the server, and took the
  fresh-provision arm — two servers, two sprites, ~21 s of provisioning
  each, a Horde name conflict that killed the loser after the fact, and an
  orphan `ready` sandbox row per occurrence. A prompt that finds a `pending`
  or `starting` row now waits for the registry to catch up
  (`ConversationServer.await_registered/2`, `:conversation_registry_settle_ms`,
  3 s by default) and hands the prompt to the server it finds; only if none
  appears — the provision died with its BEAM — does it provision fresh.
  (#800)

- **A hosted Buzz agent now shows up in other people's `@`-mention
  autocomplete.** Buzz Desktop admits a non-owned agent to autocomplete only if
  the relay carries a kind:10100 directory entry for it saying which channels
  it listens in and whom it answers — and nothing published one, so even with
  `respond_to: anyone` a hosted agent was mentionable by its owner alone (the
  owner's desktop knows it locally). The pin moves to
  `buzz-acp-v0.5.14-fountain.4`, carrying block/buzz#6097: the harness
  publishes that entry at startup and again on every membership change, from
  the channels it actually subscribes to and its real author gate. Fountain's
  `BUZZ_ACP_DISPLAY_NAME` becomes the advertised name. #776 now waits on #6097
  too. (#790)

- **Suspend-aware usage metering: parked sandbox time no longer inflates
  sandbox-minutes (#665).** A sandbox that suspended and later terminated
  billed its entire parked interval as run time. New `sandbox_suspended` /
  `sandbox_resumed` usage events now bracket each parked span, and the
  `usage_summary`/`usage_summaries` roll-up subtracts it from the
  `sandbox_terminated` `duration_ms` — including the case where a parked
  sandbox is torn down (account deletion, tenant reap) without ever waking
  again, closed against the terminated event itself. A `suspended → ready`
  wake still emits no second `sandbox_provisioned`. Understated minutes for a
  sandbox that stays suspended forever (no `sandbox_terminated` at all) are
  unchanged — see decisions/0017.

- **`!shutdown` no longer restart-loops a hosted harness.** The supervisor
  restarts `buzz-acp` on any exit and the fresh process replayed the same
  `!shutdown` from its subscription backlog — five exits per command before
  the message aged out, ending *online*. The harness now ignores owner
  control commands created before it started (block/buzz#6104). The pin moves
  to `buzz-acp-v0.5.14-fountain.3` for both changes.

- **A hosted Buzz agent now honors the desktop's "respond to" policy — anyone
  (or an allowlist) can `@`-mention it, not just its owner.** `buzz-acp` takes
  its inbound author gate from `BUZZ_ACP_RESPOND_TO` and defaults to
  `owner-only`; the desktop sets that when it spawns the harness itself, but the
  Fountain-hosted harness never got it, so every hosted agent silently dropped
  mentions from anyone but the owner whatever the record said. The
  `buzz-backend-fountain` provider now forwards the desktop's `respond_to` /
  `respond_to_allowlist`, `POST /api/buzz/agents` accepts and stores them on the
  identity, and the launch sets `BUZZ_ACP_RESPOND_TO` (and the allowlist var in
  `allowlist` mode). A converging deploy that changes a launch-relevant field
  (the gate, the environment override, relay, display name or agent) now
  restarts the running harness so it takes effect — previously a re-deploy onto
  a running harness was a no-op. Rebuild the provider binary to pick this up.
  (#790)

- **Owner control commands (`!rotate`, `!cancel`, `!shutdown`) now work from
  the Buzz Desktop composer.** The hosted `buzz-acp` required the message body
  to be *exactly* the command, but Desktop renders the `@Name` mention into the
  body, so `@Fountain Maintainer !rotate` reached the agent as an ordinary
  prompt and a bare `!rotate` was dropped for lacking the `p` tag. The fork pin
  moves to a build carrying block/buzz#6101 (`buzz-acp-v0.5.14-fountain.2`),
  which matches the command with mention text around it. #776 still tracks
  the repin to upstream — it now waits on #6101 as well as #6088.

### Removed

- **Billing debt 2/3: dead Stripe plumbing and the last plan-era wording.**
  `Billing.attach_stripe_customer/2` (no callers), the admin user page's
  "Invoices" section (it always rendered "None."), the unreachable "nothing
  is paused yet" branch of the credits-exhausted email, and
  `Credits.summary/2`'s duplicate `turn_hour_cents` (read it from
  `price_card.turn_hour`; the API field is unchanged). The `/admin/users`
  "Plan" column is "Credit"; every remaining "plan"/"tier"/"trial"/
  "subscription"/"invoice" string in operator-visible text, docstrings,
  comments, docs and test fixtures (CLI, SDK, Elixir) says what the code
  does now.

- **Credits cleanup 2/3 (#1127).** The dead code and the dead columns the
  subscription era left behind. Eight `users` columns are dropped by
  migration (`plan`, `stripe_subscription_id`, `subscription_status`,
  `trial_ends_at`, `subscription_synced_at`, `cancel_at_period_end`,
  `current_period_start`, `current_period_end`). Gone with them: the
  `:assign_subscription_state` LiveView hook, `Quotas.check_sandbox_quota!/2`
  and `QuotaExceededError`, `Billing.billing_period/2` and
  `turn_hours_used/2` (callers use `current_month_range/0` and
  `usage_summary/3`), the `subscription_required` error (every 402 is
  `insufficient_credits`), the `grant_tier` ledger reason, and the admin
  `trial.extended` / `plan.changed` / `stripe.resynced` events. Renames:
  `Billing.sync_subscription/1` → `apply_event/1`, `Workers.CreditGranter` →
  `CreditExpirer`, the `grant_trial` ledger reason → `grant_opening` (data
  migration), the funnel's `subscribed` stage → `funded`
  (`fountain_funnel_funded` in Grafana), `Credits.enforcing?/0` folded into
  `active?/0`. `Quotas.sandbox_limit_for/1` reports 0 for an unfunded
  account rather than the floor the gate would refuse anyway. SDK 1.1.0
  drops `period.source` from the billing response.

- **The May-2026 planning material is gone from the tree.** `plan/`,
  `superpowers/`, `OPERATING_MODEL.md` (the orchestrator briefs, specs and
  bible from the aod-ex rebuild), `runbooks/` (the completed home-cloud
  cutover) and `docs-redesign/` (the executed docs IA plan, #903) were
  historical records with no reader; git history keeps them. The three files
  tooling still cites moved to `standards/`: `voice-and-style.md`
  (`scripts/docs-style.py`), `simplified-technical-english.md`
  (`.vale-ste.yml`) and `catalog-template.md` (linked from the catalog).
  `rel/` stays: `rel/overlays/bin/migrate` is the migration Job entrypoint.
- **`ROADMAP.md` and the `/bootstrap` skill went with them.** Both were the
  captain-picard orchestrator's bus files; the roadmap's "Now" had been empty
  since the 2026-05-10 launch. The one thing they said that nothing else did,
  the 100-WAU goal and the org/team gate behind it, moved to `CLAUDE.md`;
  NC-6 is recorded in ADR 0007 and #1039.

- **The GitHub Pages documentation site.** `docs/` had two publishers: the
  in-app manual at `/docs`, embedded at compile time by `Fountain.Docs`, and a
  MkDocs Material build deployed to `binarybourbon.github.io/fountain` on every
  push to `main`. They served the same markdown from the same nav, so the
  second one bought nothing and cost a workflow, a `mkdocs build --strict` step
  in two CI jobs, a Python toolchain, and a second renderer whose dialect the
  first had to keep chasing. `/docs` is now the only place the manual is
  published. It is public and needs no account, which is what made the Pages
  copy redundant rather than load-bearing.

  Gone with it: `.github/workflows/docs.yml`, `mkdocs.yml`,
  `docs/requirements.txt` and the `mkdocs build` CI steps. The nav moved to
  **`docs/nav.yml`**, same format, same parser, now inside the tree it
  describes, so it needs no Dockerfile `COPY` and no special case in the CI
  docs-path filter.

  Two things the Pages build was quietly doing, both now handled:

  - MkDocs built every page under `docs/` whether the nav named it or not, so
    four pages under `docs/superpowers/` reached the public site while being
    invisible at `/docs`. They are internal planning material from May 2026;
    they moved to `superpowers/` at the repo root, beside `runbooks/`. A new
    test fails on any page under `docs/` that the nav does not name, since such
    a page is now published nowhere at all.
  - `mkdocs build --strict` was the link checker. `docs_test.exs` already
    checked every internal `/docs` link *and* every anchor, which MkDocs never
    did, and it runs on every pull request rather than after the merge. It is
    now the whole structural gate. The prose gates (`scripts/docs-style.py`,
    `vale lint docs`) are unchanged.

  Links into the old site from `README.md`, `CHANGELOG.md`, `docker-compose.yml`,
  `deploy/k8s/` and the SDK examples now point at
  `https://fountain.inevitable.fyi/docs/...`. Four of them had been broken
  since the docs IA campaign moved that content, because nothing checked
  absolute links; they point at the right pages now (#1008)

  The old site does not simply stop: it becomes a **tombstone**, one redirect
  per URL it used to answer, each pointing at the same page under `/docs` and
  carrying the fragment across. Deleting the workflow would have left the last
  snapshot serving forever, which is worse than a 404, and deleting the site
  would have broken every link anyone ever made to it.
  `scripts/build-pages-tombstone.py` generates it from the nav and refuses to
  emit a redirect to a page that is not there;
  `.github/workflows/pages-tombstone.yml` publishes it by hand and is
  `workflow_dispatch` only, so it is not a docs publishing path (#1011)

## [0.12.0] — 2026-08-17

One agent config, many baselines: a conversation can now be provisioned from
an environment other than its agent's, from the API, the CLI, and a hosted
Buzz identity. Also the channel-bound conversations that keep a restarted
`buzz-acp` on the same sandbox, and three fixes for hosted harnesses and ACP
turns across deploys.

### Upgrade notes

- **A migration adds `conversations.environment_id`,
  `buzz_identities.environment_id` and `agents.allowed_environment_ids`.**
  Additive and nullable; runs on boot as usual. Existing conversations and
  identities keep behaving exactly as before (nil = the agent's environment).
- **One-time step for hosted Buzz harnesses started before this release**:
  a harness that predates the launch-in-child fix below keeps its old Horde
  spec (stale launcher path + revoked key) until it is stopped and started
  once. Disable and re-enable each Buzz agent after the upgrade.
- **`buzz-backend-fountain` provider settings gain an optional
  `environment` selector.** Rebuild/reinstall the provider binary to see it in
  the Buzz desktop; existing deploys need nothing.

### Added

- **Per-launch environment override (#783).** A conversation may be provisioned
  from an environment other than its agent's: `environment_id` on
  `POST /api/conversations`, `--environment` on `fountain acp` and
  `fountain run`, `environment_id` on the hosted-Buzz provision request
  (the identity's harness passes it through), and an optional `environment`
  selector in the `buzz-backend-fountain` provider's settings. One agent config can now run
  under N environments — a "fountain engineer" and a "buzz engineer" no longer
  need to be two agents. The override is pinned to the conversation across
  wakes and is part of the `channel_id` resume key. Agents get
  `allowed_environment_ids`, the same shape as `allowed_vault_ids`, to scope
  which environments may stand in for a reviewed one; the agent's own always
  passes.

- **Channel-bound conversations (#774).** `POST /api/conversations` accepts
  an opaque `channel_id`; when set, the latest live conversation for the same
  agent, vault and channel is resumed (200, `meta.resumed: true`) instead of
  a new one being opened (201). `fountain acp` forwards `_meta.channelId`
  from `session/new`, so a chat harness that forgets its sessions on restart
  — `buzz-acp`, on every hosted deploy — lands back on the same conversation
  and sandbox. The hosted `buzz-acp` is built from a fork carrying the
  upstream change that sends the channel id (block/buzz#6088;
  `buzz-acp.source`) until it merges — #776 tracks the repin.

### Fixed

- **Two hosted harnesses for one Buzz identity no longer both run.** When two
  nodes ran the boot sweep before the cluster formed, both registered a
  harness and Horde told the loser to exit — but the harness traps exits and
  swallowed the `:name_conflict` message, so two `buzz-acp` processes
  answered the same channel and raced one conversation (`conversation_busy`
  on every second prompt). The loser now stops: port closed, buzz-acp
  reaped, its launch key revoked.
- **A hosted Buzz harness survives deploys and version bumps.** Horde replays
  a harness's child spec on every deploy, and the spec carried the launch:
  the launcher path (`/app/lib/fountain-<version>/priv/buzz-acp-launch.sh`,
  stale after the next version bump — the harness crash-looped on `No such
  file`) and the minted `FOUNTAIN_API_KEY` (revoked by the old node's
  `terminate/2`, then replayed by the new one). The spec now carries only the
  identity id; the launch — key, env, launcher — is resolved by the child's
  start on whichever node runs it. **One-time step after upgrading:** a
  harness started before this fix keeps its old spec until it is stopped and
  started once (disable and re-enable the Buzz agent).
- **An ACP turn in flight across a deploy no longer hangs.** Every deploy
  restarts every `ConversationServer`; the agent in the sandbox keeps running
  and the server reattached to its session — but on the ACP path it reattached
  with no peer, so nobody answered the agent's `session/request_permission`
  and nobody saw the `session/prompt` response. The turn sat `running` until
  the user prompted again (which interrupts it) or the sandbox hit its
  lifetime ceiling. The peer now records the prompt's JSON-RPC id on the turn
  and a reattach starts a peer in attach mode that resumes exactly that
  request; a turn whose prompt was never sent is orphaned cleanly instead of
  left to hang. Replayed output is de-duplicated by content: sprites replays
  the last 16 KiB of the session, not the whole buffer, so the byte-count
  skip could not apply.

## [0.11.0] — 2026-08-16

Fountain can now **host a Buzz agent** — a Nostr identity whose coding-agent
body runs in a Fountain sandbox, with its signing key held server-side in a
vault and no desktop required (ADR 0020, gates 1–4). Minor, not patch, because
the release image changes underneath: new base image, three baked binaries, and
a background supervisor that starts on boot.

### Upgrade notes

- **Runtime base image is now `debian:trixie-slim`** (was bookworm). The
  shipped `buzz-acp` needs glibc ≥ 2.38, which bookworm does not have. If you
  run the published image, nothing to do; if you build your own runtime stage
  on bookworm, `buzz-acp` will not start there.
- **The image now bakes three extra binaries**: `buzz-acp` and `buzz` (built
  by us for amd64 **and** arm64 from the pinned block/buzz source, checksum
  verified at build time) and the `fountain` Go CLI. `runtime.exs` finds them
  at their baked paths; `BUZZ_ACP_BASE_URL` / `FOUNTAIN_CLI_PATH` exist only
  for a non-standard layout (see the configuration reference).
- **A boot sweep starts a `buzz-acp` harness for every enabled Buzz identity**
  (Horde-supervised, one per identity, cluster-wide). With no identities
  provisioned it is inert — no new process, no new egress.
- **New migration** for `buzz_identities`. Runs with `mix ecto.migrate` /
  the release migrator as usual.
- **Markdown rendering moved to a Rust NIF** (MDEx / comrak, precompiled).
  The published image is a supported target; a from-source build on an
  unsupported platform needs a Rust toolchain.

### Added

- **Hosted Buzz agents.** A `BuzzIdentity` binds a Nostr keypair (kept in a
  vault, never in the row) to a Fountain agent; a supervised `buzz-acp`
  harness per identity keeps the agent online on its relay and drives
  `fountain acp` for each mention, off the user's desktop (#739, #740, #742,
  #745). Provision one with `POST /api/buzz/agents` (idempotent on the
  pubkey; the nsec is stored server-side and never returned), list with
  `GET`, tear down with `DELETE /:id` (#753, #754) — or from the Buzz
  desktop via the new **`buzz-backend-fountain`** remote-agents provider
  binary in `cli/` (#755).
- **The reply path — the sandbox never sees the key.** A Buzz-driven
  conversation gets a Fountain-hosted MCP server injected at `session/new`
  (`POST /api/mcp/buzz/:conversation_id`, authenticated with the sprite
  token) exposing `buzz_send_message` and `buzz_react`; Fountain resolves the
  agent's key server-side and publishes through the baked `buzz` CLI, with
  credentials in the environment, never in argv (#750, #751, #752). A
  successful publish audits `buzz.published` without the message content.
- **`buzz-acp` diagnostics reach the pod log**, tagged per identity, so
  `kubectl logs` shows relay connection and presence (#747); and the desktop's
  ACP activity panel populates (`BUZZ_ACP_RELAY_OBSERVER`, #756).
- **OpenClaw is a documented ACP client** of `fountain acp` — config-only via
  its `acpx` plugin, verified against the real acpx 0.11.2 and a live gateway
  (#757, #758, #759, #760). New page at `/docs/integrations/openclaw`.
- **Buzz integration page** in the in-app docs, with inline SVG diagrams —
  the docs renderer gained a trusted path that keeps a scrubbed
  `<figure>`/`<svg>` block as real markup for the in-repo corpus only; agent
  output is still fully escaped (#761).
- **`decisions/` is an OKF bundle**, validated in CI, with a generated index
  (#741); ADR 0020 records the Buzz-at-the-gateway design (#734).

### Changed

- **Markdown rendering moved from Earmark to MDEx.** Earmark is retired
  upstream (`mix hex.audit` flags it as unmaintained), and it sat under
  the XSS-hardened renderer for agent output and the in-app docs. The
  same guarantees hold on MDEx (comrak): raw HTML is neutralized to text
  on the untrusted path, `javascript:`/`data:` URLs are dropped, and the
  docs corpus keeps its scrubbed SVG diagrams. Two visible differences:
  a link or image with a dropped URL is now unwrapped to its text/alt
  instead of rendered as an element with no `href`/`src`, and an
  HTML-comment block is dropped rather than shown as escaped text (#762).

- **`fountain acp` implements `session/set_config_option`** as
  accept-but-do-not-apply — a Fountain agent's model is set on the agent, so
  a client's push is acknowledged and ignored rather than rejected as
  method-not-found, which OpenClaw's acpx treated as fatal (#759).

### Fixed

- **A hosted `buzz-acp` is reaped on stop, not orphaned.** buzz-acp closes
  the BEAM's pipe while it keeps running, which both faked an exit (a
  restart → duplicate harness) and survived `Port.close` (an agent that stays
  online after stop, across deploys). A launcher middleman now delivers one
  true exit status and TERM→KILLs the child on close (#746).
- **`fountain acp` no longer trips OpenClaw's session-control sync.** The
  `session/set_config_option` reply advertised a config-option list, and
  acpx narrows the controls it will push to whatever that list says — so the
  next control (`thinking`) failed with "does not advertise config option"
  and the gateway turn died. The reply now carries no list (Fountain has no
  per-session options; the agent's model is authoritative) and says
  `_meta.fountain.applied: false`. The full OpenClaw gateway round trip —
  brain → `sessions_spawn` → acpx → `fountain acp` → sandbox → reply — is
  green against the real acpx 0.11.2 (#760).

- **In-app docs anchor links land on their section.** `/docs` and `/help`
  headings now carry GFM-style ids, so the docs' `#anchor` cross-links
  (e.g. `/docs/architecture#the-secrets-model`) scroll to the heading
  instead of the top of the page, matching the public MkDocs site (#765).

## [0.10.2] — 2026-08-15

### Fixed

- **The CLI shows agent output again.** Since ACP became the only path
  for claude, codex and opencode, `fountain run` printed a turn starting
  and finishing with nothing in between: the renderer only understood
  claude's own stream-json, so every protocol line rendered as empty.
  Agent text, tool calls and thinking now appear, matching how the
  legacy path always looked (#723).

- **A lost wake race no longer strands a conversation on a dead
  sandbox.** Waking a dormant conversation repointed it at its new
  sandbox *before* the server started; when the start lost the race, the
  loser terminated its own row without undoing that, leaving the
  conversation naming a sandbox it had just retired while the winner
  served turns on another. Visible as a conversation that reads
  `terminated` through the API while it answers normally, an orphan
  sandbox nothing references, and a quota slot spent twice. The row is
  now repointed only after the server starts — which also means a loser
  can no longer retire the sandbox a winner is reusing (#717).

- **A model the runtime refuses is no longer invisible.** The turn still
  continues on the runtime's default, but the notice went only to
  `stderr` — the one stream `?streams=acp,stage` drops and `fountain
  acp` treats as noise, so an editor never heard. It is now a
  `model`/`failed` stage event carrying the requested model and the
  runtime's own explanation, which the conversation view, the API, the
  CLI and an editor's log all receive (#724).

## [0.10.1] — 2026-08-15

### Added

- **`fountain acp --vault <name-or-id>`** attaches a vault to every
  conversation an editor entry opens. Vault values override the agent's
  environment, so this is where a secret belonging to *that entry* goes —
  an identity the agent posts under, a token scoped to one workspace. Two
  entries pointing at the same agent stay separate; the same secret in a
  shared environment would be used by every agent attached to it, which
  is a good way to have one agent publish under another's name.

## [0.10.0] — 2026-08-15

### Upgrade notes

- **Sprites sandboxes now expose their HTTP endpoint publicly.** Every
  sprite already had a URL; it required a platform credential to open,
  which meant a web service an agent started could not be reached by the
  person who asked for it. Fountain now sets `url_settings.auth =
  "public"` when it creates a sandbox, so **anything an agent serves is
  reachable by anyone who has the URL** (a name plus a random suffix,
  not guessable, but not secret either). Set
  `config :fountain, :sprites_public_urls, false` to keep the previous
  behaviour: sandboxes keep their URLs, and only a token holder can open
  them. E2B and Daytona are unaffected — they expose per-port hostnames
  rather than one sandbox URL, and report no URL at all.

### Added

- **A sandbox can tell you where it is running.** Agents asked "what's
  the URL?" had no way to answer: the platform assigns the endpoint
  outside the sandbox, and inside it the hostname is just `sprite`. The
  URL is now stored on the sandbox, returned as `sandbox.url` on the
  conversation API, and set inside the sandbox as **`SANDBOX_URL`**.
  Providers that have no such endpoint report `:unsupported` rather than
  a guess — a URL that does not resolve is worse than none, because the
  agent hands it to a human who then blames the service.

## [0.9.1] — 2026-08-15

### Fixed

- **ACP clients could not add a Fountain agent.** Buzz refused one with
  "unknown reported no models. Check that the CLI is installed and signed
  in" — a message about a different problem. Two fields the protocol
  expects were missing: `initialize` sent no `agentInfo`, so a client had
  no name for us but "unknown", and `session/new` reported no model
  state, which reads as an agent that cannot run anything. Both are now
  sent; the model list is the agent's own model, since that is what every
  conversation on it runs (#721).

### Added

- **`fountain --version`.** The binary had no version at all, which is
  why the ACP handshake had none to report. Release builds stamp the tag
  in; a build from source says `dev`.

## [0.9.0] — 2026-08-15

### Upgrade notes

- **ACP is now the only way Fountain talks to claude, codex and opencode.**
  The legacy spawn path is deleted and the per-agent `metadata["acp"]`
  opt-out is retired — see *Changed* below. Nothing is required of an
  operator, but the change is worth knowing before you upgrade: those
  runtimes now carry their MCP servers, session ids and tool spans over
  the protocol rather than through argv and config files. Gemini agents
  are untouched and stay on their legacy path (#658, #659).
- **Sandbox backends are pluggable, and Sprites remains the default.** An
  instance that sets nothing keeps behaving exactly as before.
  `SANDBOX_PROVIDER` picks a different default (`sprites`, `e2b`,
  `daytona`), each provider needs its own API key, and E2B and Daytona
  need a prepared template/snapshot before they will run anything.
- **Two additive migrations** (`sandboxes.provider`,
  `agents.sandbox_provider`); both run automatically on boot per the
  standard upgrade flow.

### Added

- **Drive a Fountain conversation from your editor.** `fountain acp` is a
  new CLI subcommand that speaks the
  [Agent Client Protocol](https://agentclientprotocol.com) on stdio, so an
  ACP-capable editor — Zed and friends — can open a conversation on one of
  your agents, prompt it, watch messages, thoughts and tool calls stream in,
  cancel a running turn, and reopen the transcript later. The turn runs in
  Fountain, not in the editor: close the laptop mid-turn and it keeps going.
  It is a control surface, not a workspace — the agent works on its sandbox's
  files, declares no access to the ones open in your editor, and deliberately
  does not send sandbox paths as clickable locations. Agents on a runtime
  that does not speak ACP are refused by name. Setup and editor config are on
  the new [Editors (ACP)](https://fountain.inevitable.fyi/docs/integrations/editors)
  page (ADR 0015; #709, #698–#707).

- **The conversation event stream is documented as the interface it now is.**
  Both `GET /api/agents/:id` and `GET /api/conversations/:id` gained a derived
  read-only `acp` boolean, and the SSE endpoint's `?streams=` parameter now
  documents every stream it carries — including `acp`, one ACP
  `session/update` notification per line — plus the event envelope's fields.
  Two clients render from this stream now, so its shape carries compatibility
  obligations (#702, #707).


- **The documentation site is served in-app at `/docs`.** The same markdown
  GitHub Pages publishes is embedded at compile time and rendered through
  the app's sanitizing markdown pipeline, with the sidebar mirroring the
  `mkdocs.yml` nav (a test fails on drift). Public, like the Pages site;
  the curated `/help` topics are unchanged and now link to it.

- **Pluggable sandbox backends: E2B and Daytona join Sprites.** The
  sandbox layer is a provider-agnostic behaviour (`Fountain.Sandbox`) with
  an executable conformance suite; `SANDBOX_PROVIDER` picks the instance
  default, an agent can pin `sandbox_provider`, and every sandbox row
  records the provider that owns it — parked sandboxes always wake where
  their disk lives. E2B (`E2B_API_KEY`) pauses idle sandboxes with a
  filesystem+memory snapshot; Daytona (`DAYTONA_API_KEY`) stops them with
  the disk preserved. A provider that cannot park degrades to
  destroy-on-idle, and the reaper reconciles each provider independently.
  Reference sandbox images live in `images/e2b/` and `images/daytona/`;
  decisions/0018 has the full design (#676–#686).

- **Tool-level OTel spans for every ACP runtime.** Tool-call tracing was
  claude-only (a parser over its proprietary stream-json); ACP's
  `tool_call`/`tool_call_update` carry the id and status for all runtimes,
  so every ACP turn now emits `fountain.tool_use` child spans plus
  `fountain.text_bytes`/`thinking_bytes`/`tool_calls` turn totals. Cost
  and token-usage attributes do not exist on the ACP path — the protocol's
  stop reason carries no usage block (#637).

### Changed

- **The sandbox docs now tell the provider story straight.** The docs site
  gets a "Sandbox providers" section — one contract
  (`Fountain.Sandbox` + its conformance suite), three implementations
  (Sprites, E2B, Daytona) — with a new contract overview page, and the
  Sprites page no longer claims to be the only backend.

- **The four dialect parsers are out of the conversation LiveView.** The
  24 `event_blocks/2` clauses move to a dedicated, tested
  `LegacyBlocks` module: gemini's dialect stays live (#659), and the
  claude/codex/opencode parsers are frozen — they render pre-ACP
  history only and are deleted when that history ages out. The rule
  this closes: a dialect parser is never written again; a runtime that
  doesn't speak ACP gets an adapter at the sandbox boundary (#642).
- **The legacy spawn path for claude, codex and opencode is deleted; ACP
  is the only way Fountain talks to them.** The three `build_command/5`
  argv builders go — and with them `--dangerously-skip-permissions`,
  `--dangerously-bypass-approvals-and-sandbox`, codex's
  resume-by-guessing `--last`, and the claude-only stream-json OTel
  tracer (superseded by the protocol-wide ACP tracer). The per-agent
  `metadata["acp"]` flag is retired: with no legacy path left there is
  nothing to opt out into, and stale metadata is ignored. The ACP
  decision now keys on the conversation's runtime rather than the agent,
  so conversations whose agent was deleted keep working. Gemini keeps
  its full legacy stack until its `session/load` is fixed upstream
  (#658, #659).
- **MCP servers now reach claude, codex and opencode agents through the
  protocol, not the sandbox.** The three out-of-band mechanisms — claude's
  `mcp add-json` provisioning loop, codex's `config.toml` writer,
  opencode's `opencode.json` writer — are deleted; `session/new`'s
  `mcpServers` param is the single path (#636). Consequence for the
  `"acp": false` escape hatch: an opted-out agent runs its legacy turns
  without MCP servers. Gemini's argv mechanism stays with its legacy
  path.
- **ACP is now the default protocol for claude, codex and opencode
  agents.** The per-agent `metadata["acp"]` flag flips polarity: instead
  of opting in with `true`, agents on those runtimes speak the Agent
  Client Protocol unless the agent carries `"acp": false` (an operational
  escape hatch, set over the API). Gemini agents stay on the legacy path
  until gemini's `session/load` is fixed upstream (#658, #659). ADR 0014
  gate 4 begins here.

### Fixed

- **A filtered replay dropped ACP events entirely.** `?streams=` has two
  implementations — one for history, one for live events — and the history
  one carried a list of stream names written before ACP existed, so
  `?streams=acp` returned a conversation's future and none of its past. The
  editor integration's `session/load` replayed an empty transcript and every
  mid-turn reconnect silently lost the updates it missed. The filter no
  longer keeps a list, and one test now runs the same cases through both
  halves (#716). This is the API-side sibling of the rendering bug fixed in
  0.8.1 (#669): both were a stale allow-list meeting a new stream name.


## [0.8.1] — 2026-08-13

### Fixed

- **ACP agents' replies now render in the conversation view.** Since the
  ACP conversion, an ACP-flagged agent's output — stored under its own
  event stream — was filtered out by all three view modes, which still
  keyed on `stdout`: the transcript showed the agent never answering while
  the API and CLI streamed the reply fine. ACP output now follows the
  stdout pill, including for accounts with stream preferences saved before
  the flag existed (#669).

## [0.8.0] — 2026-08-13

### Upgrade notes

- **Sandboxes now rest in a new `suspended` status instead of being
  destroyed when idle.** Suspended sandboxes keep their sprite alive at
  sprites.dev indefinitely (scaled to zero; treated as free) and do not
  count toward the concurrent-sandbox quota. Anything consuming the API's
  sandbox `status` field needs to accept the new value, and operators
  who relied on idle reclaim to clean up sprites should know it no longer
  does — only the max-lifetime ceiling, explicit termination, tenant
  suspension and account deletion destroy sprites now.
- **One additive migration** (`sandboxes.last_resumed_at`); it runs
  automatically on boot per the standard upgrade flow. No new required
  configuration.

### Added

- **Agents can opt into speaking the Agent Client Protocol to their
  runtime.** Setting `metadata.acp: true` on an agent whose runtime is
  `claude`, `codex` or `opencode` replaces the per-turn CLI invocation with
  an ACP connection scoped to the turn: prompts, images and MCP servers are
  carried over the protocol, `agent.model` is honored on every turn, and
  follow-up turns resume the runtime's own session (`session/resume` or
  `session/load`, whichever the adapter advertises). The legacy path remains
  the default and is unchanged (#647, #648, #656). `gemini` is deliberately
  held back from the flag until its upstream `session/load` can find the
  session it just wrote — a flag set on a gemini agent is a no-op, not an
  error (#659, #660, #661). The design record is decisions/0014 through
  0016.

### Changed

- **An idle sandbox is suspended rather than destroyed, and the next prompt
  reattaches to the same sprite — the agent keeps its memory of the
  conversation.** Idle reclaim was built on the premise that an idle sprite
  bills until destroyed; it doesn't (sprites scale themselves to zero), and
  the destroy was silently costing every idle conversation its runtime
  session (#649). The max-lifetime ceiling still destroys — it exists to
  bound runaway busy compute — and its message still says honestly that the
  agent will not remember. The ceiling now measures a continuous run
  (restarting on each wake) rather than calendar age, so a conversation
  parked for a week is not destroyed the moment it is woken. See
  decisions/0017.
- **Environment warm-start checkpoints are no longer created.** A
  checkpoint id is scoped to the sprite that made it, and an environment's
  checkpoint was only ever restored into a *different* sprite — so every
  restore failed and the checkpoint only spent time and storage. Creation
  is now off by default behind a flag, ready to re-enable if the platform
  grows a create-from-checkpoint call (#654).

### Fixed

- **ACP authentication only ever uses an API-key method, never whatever the
  adapter listed first.** The fallback could pick an interactive login flow —
  which a headless sandbox can never complete, leaving a turn in flight
  forever, disarming idle reclaim and billing the sprite to its ceiling.
- **Checkpoint creation never actually captured an id** — the extractor
  matched a shape the library doesn't emit, so `checkpoint_id` was never
  written and every restore was skipped; the id is now read from the
  checkpoint listing (#653). Moot for warm starts since checkpoints stopped
  being created (#654, above), but the restore path is correct if
  re-enabled.

## [0.7.0] — 2026-08-07

### Upgrade notes

- **No migrations, and no new required configuration.** An instance on
  v0.6.x upgrades by taking the new image.
- **`agent.model` now takes effect on the `claude`, `codex` and `gemini`
  runtimes, where it was previously ignored.** Those three built
  model-agnostic argv, so an agent configured for
  `anthropic/claude-haiku-4-5` ran whatever the CLI defaulted to. After this
  release it runs the model it says it runs — which is the point of the
  field, but it means an existing agent can start using a different model,
  with different cost and latency, without its config having changed. Check
  the model on agents you did not deliberately set (#553)
- **An agent whose provider cannot be reached by its runtime is now rejected
  on write.** `anthropic` for `claude`, `openai` for `codex`, `google` for
  `gemini`; `opencode` is unconstrained as the only multi-provider
  front-end. Previously such a pairing saved cleanly and did nothing; now it
  would ship a model flag the CLI cannot serve, so the changeset refuses it.
  **Existing rows are not migrated or validated** — the check runs on write,
  so a stored mismatch surfaces the next time that agent is edited, not at
  upgrade. Across production, all 45 agents were already `claude`/`anthropic`
  with model ids the CLI accepts (#553, #554)
- **Audit rows written from here on use a converged actor vocabulary.** Email
  verification records `ui` or `api` rather than the bare `system` it derived
  before a session exists, and operator-driven billing transitions record
  `admin` rather than `system:admin`. Rows already written keep their old
  spelling, so anything you query or alert on by actor needs to accept both
  (#604)

### Added

- **The agent form suggests models, and a misspelled provider is caught at
  save time.** `agent.model` was format-checked and nothing more, so
  `anthopic/claude-sonnet-4-6` saved cleanly and then failed inside the
  sandbox: `opencode` reads the prefix to decide which API key to export and
  falls through to none for an unrecognised one, so the run started with no
  inference credentials at all and died as an auth error in the conversation
  log. The provider is now validated on write against the three Fountain
  actually holds credentials for — `anthropic`, `openai`, `google` — and the
  model field offers a `<datalist>` of current models, scoped to the selected
  runtime so it can't lead you into the runtime/provider mismatch #553 added.
  The **model id is deliberately still unchecked**: type anything and it is
  passed to the CLI as-is (the form says so), so a model released after your
  Fountain version works without waiting for a release (#554)

- **`MIGRATE_ON_BOOT=false` — run migrations somewhere other than at boot.**
  The release migrates before it serves, on every replica, which is right for
  the single-replica shape it ships as and rules out the standard Kubernetes
  shape: migrations once in a Job, app pods that only serve. The switch turns
  the boot-time migration off — both the paths that did it, the image's `CMD`
  and the `Ecto.Migrator` child in the supervision tree — and leaves
  `bin/migrate` untouched, since that is what the Job runs. Default unchanged:
  an instance that sets nothing migrates exactly as before. Nothing checks
  that the Job ran, so ordering it before the rollout is the operator's job;
  [the guide](https://fountain.inevitable.fyi/docs/guides/operate/database#run-migrations-in-a-job)
  and `deploy/k8s/README.md` say so and carry the manifest (#610)

### Changed

- **The audit trail's actor vocabulary is closed, and the rules behind it are
  now a decision rather than a habit.** `decisions/0013-audit-trail.md`
  records what the #540 campaign settled — mutations audit inside the context,
  never inside a transaction, never recording values — and fixes the call
  sites that had drifted from it. The members are `self`, `ui`, `api`,
  `sprite`, `admin`, `admin:<operator_id>` and `system:<worker>`; a bare
  `system` is now a defect signal rather than a value, since the only routes
  that produced it — email verification, which runs before a session exists —
  are always a person whose surface the call site knows. Operator-driven
  billing transitions record `admin` instead of claiming to be unattended as
  `system:admin`. A guard test fails the build on an actor outside the set,
  or on an ADR that has stopped naming one (#604)

### Fixed

- **`agent.model` is honored on the `claude`, `codex` and `gemini` runtimes.**
  The field is required, format-validated and front-and-centre in the agent
  form, but only `opencode` ever read it — the other three built
  model-agnostic argv, so an agent set to a cheaper or larger model silently
  ran the CLI's default with no error and no signal the setting did nothing.
  All three CLIs do take a model flag, each wanting the bare id rather than
  the canonical `provider/model_id`; that translation now lives in one place,
  and `opencode` keeps receiving the prefixed string it uses to pick an API
  key. See the upgrade notes — an agent that was quietly running a default
  will change model on upgrade (#553)

- **Two replicas booting together against an empty database no longer race
  each other into a restart.** Ecto's default migration lock is a row lock on
  `schema_migrations` — which cannot serialize the creation of
  `schema_migrations` itself, the one moment on a virgin database when both
  replicas are inside `Ecto.Migrator` at once. The loser died on the type's
  unique index (`pg_type_typname_nsp_index`), Kubernetes restarted it, and the
  retry succeeded: a benign `RESTARTS 1` that reads exactly like a crash loop
  on a first deploy. The lock is now a Postgres advisory lock, taken before
  anything touches the table. Only ever observed at two or more replicas on a
  brand-new database (#610)

## [0.6.1] — 2026-08-07

### Fixed

- **A turn that fails before it starts now says why.** When a runtime exits
  before it reads the prompt, it has already sent its exit code and whatever
  it printed on the way out — but those arrived just after the turn was
  marked failed, on the one path that never registers the command they
  belong to, so they were dropped without a trace. `turns.exit_code` stayed
  `NULL` and every such failure reported the same `:command_exited`: an
  expired key, a renamed binary and an OOM kill were indistinguishable. The
  turn now records the exit code, keeps the runtime's last lines of
  stdout/stderr as ordinary turn output, and reports
  `:command_exited (runtime exited 1)`. The outcome is unchanged — this is
  the diagnosis #603 left missing (#608)

- **`Fountain.Release.verify_email/1` no longer reports failure for work it
  completed.** The account was verified, the first-admin bootstrap ran, and
  then the task crashed on a PubSub broadcast and exited non-zero having
  printed nothing but a stack trace — so any caller checking the exit code
  concluded it had failed and an operator re-running it saw the same crash on
  an already-verified account. The broadcast exists so a waiting page in one
  tab advances when the link is clicked in another, and the release VM starts
  the Repo and nothing else on purpose; it is now skipped when there is
  nobody to hear it. The web paths are unchanged, and `promote_admin/1` was
  never affected. Regression in v0.6.0; v0.4.1 and earlier are unaffected
  (#609, #614)

## [0.6.0] — 2026-08-06

### Upgrade notes

- **No migrations, and no new required configuration.** An instance on
  v0.5.x upgrades by taking the new image.
- **A bearer token belonging to an account that never verified its email now
  gets `403 email_unverified`.** Verification is enforced where the identity
  is established rather than at each door, so `authenticate_api_key/1`
  refuses for such accounts and unverified browser sessions land on
  `/auth/verify-pending` instead of reaching controller routes (theme,
  avatars, export downloads, turn images, the credential POSTs). Nothing is
  affected in practice — across 163 unverified accounts, zero API keys had
  ever been issued — but a key minted before `POST /api/auth/token` was
  closed would have kept working forever, and no longer does (#533).
- **Expect `audit_events` to grow faster.** Mutations now record in the
  context rather than at whichever surface happened to remember, so the UI
  leaves the same trail `/api` always did, and background workers attribute
  their own writes. The retention pruner already covers the table and now
  records its own run; no action needed unless you have tightened retention
  on the assumption of the old volume.
- `POSTGRES_HOST_PORT` is a new optional compose variable, defaulting to
  `5432` — set it if the evaluating machine already runs Postgres there
  (#549). Existing compose files are unaffected.

### Added

- **How long a turn takes, and how long before it says anything, are now
  metrics rather than one-off traces.** Turn duration existed only in the
  `fountain.turn` OTel span and in `turns.started_at/ended_at` — a trace you
  open one at a time and a column you query by hand, neither of which backs a
  dashboard or an alert. There is now a `fountain.turn.duration` histogram
  tagged by runtime and terminal status, and a `fountain.turn.first_output`
  histogram for the gap between hitting enter and the agent visibly doing
  something, which nothing captured at all. First output is measured in bytes
  on stdout rather than parsed tokens, so claude, codex, gemini and opencode
  stay directly comparable; a turn resumed after a restart deliberately emits
  neither, since monotonic time does not survive the restart and a missing
  sample beats a wrong one (#536, #535)

- **Provisioning sub-steps have their own histograms.** `fresh_provision` and
  `reattach` have been measured since #405, so a provision getting slower was
  visible — but which step got slower was not, and attributing it meant
  grepping log lines or opening individual traces. The setup script, package
  installs, network policy, repository clones and checkpoint create/restore
  each export a histogram now, sharing `fresh_provision`'s buckets so the
  parts stay comparable with the whole. The emitters were already firing these
  spans; nothing outside the log and OTel had subscribed. No tags on any of
  them — the span metadata carries conversation and environment ids, and
  promoting one to a label mints a time series per conversation (#537)

- **The `/audit` page has the filters the API got in #526.** `GET /api/audit`
  could narrow the trail by action prefix, resource type and time window; the
  page could not, so the API was strictly better than the UI at the one thing
  the UI is for — "show me every `vault.` event since Tuesday" was a curl away
  and impossible in a browser, where you scrolled 200 rows and hoped. The
  page now takes the same four filters through the same query, with the
  resource-type list built from what is actually in your trail. Filter state
  lives in the URL, so a filtered view is a link you can send someone and it
  survives the 5s refresh. Admins get the filters over the cross-tenant view
  too — previously the person seeing the most events could filter the least
  (#572)

- **`/api/admin/*` makes operator tasks scriptable** — list and inspect
  accounts with the filters the admin UI has, set the sandbox cap, extend a
  trial, comp, suspend, resync from Stripe, delete an account, list and reap
  sandboxes, and read both the cross-tenant audit trail and the privilege
  trail. Every one of these was AdminLive-only, so a bulk trial extension or
  a suspension from an incident runbook meant a human clicking. The surface
  needs three things at once: an authenticated key, `full` scope (a
  sandbox's per-conversation token is not an operator credential even when
  the account is an admin) and the admin role. Refusals mirror the UI — no
  self-suspend, no self-delete, billing actions refused when billing is
  disabled — plus one the UI has no need for: you cannot revoke your own
  admin role, which over an API is a lockout one scripted typo away. Actions
  record the same `admin.*` privilege-trail events, so a curl'd suspension
  is as visible as a clicked one (#527)

- **Billing is self-serve over the API**: `GET /api/account/billing` for
  status, trial and period dates and the current month's usage, plus
  `POST /api/account/billing/portal` and `.../checkout` to mint Stripe URLs.
  All user-facing billing lived in `BillingLive`, so a CLI user who hit the
  subscription gate got a 402 with no programmatic way out, and an expiring
  trial was invisible — `/api/auth/me` carried `subscription_status` and
  nothing else. Checkout refuses with 409 when Stripe already holds a live
  subscription instead of quietly minting a duplicate, and refuses outright
  when Stripe cannot be asked. With billing disabled the endpoints are 404
  with `billing: "disabled"`, matching the UI's redirect. The URL-minting
  rules moved into the billing context so the LiveView and the API cannot
  drift; everything stays in `ee/` (#524)

- **Account data export and account deletion are driveable over the API** —
  `POST/GET /api/account/exports`, `GET /api/account/exports/:id/download`
  and `DELETE /api/account`. These are the closest things Fountain has to
  GDPR flows and both were browser-only. Export keeps its one-per-hour limit
  (429 with `Retry-After`) and, since the API has no PubSub, reports progress
  by polling instead of pushing; the download is the same owner-scoped,
  expiring, audited artifact the session route serves. Deletion is
  irreversible and takes the tenant encryption key with it, so it requires
  both a typed `{"confirm": "<account email>"}` body — the API equivalent of
  the UI's typed-email gate — and a `full`-scoped key, which keeps a
  sandbox's per-conversation token from destroying the account it is running
  inside (#523)

- **Agent avatars have an API**: `GET/PUT/DELETE /api/agents/:id/avatar`, and
  `avatar_media_type` is serialized on the agent so a client can tell one
  exists. Upload and delete lived only in the agents LiveView, and even
  *reading* the bytes required a session — while turn images next door
  already had both a session route and a bearer route, so `fountain apply`
  shipping an avatar file had nowhere to send it. Uploads take raw bytes with
  an image content-type or the same base64 JSON shape prompt images use, cap
  at 5 MB, and are refused with 415 for anything that is not one of the four
  accepted image types — the ingest half of the rule that keeps
  client-declared `text/html` from ever being servable from the app's own
  origin (#528)

- **Onboarding can be completed over the API** —
  `POST /api/account/onboarding/complete`, with `GET /api/account/onboarding`
  and new `onboarding_state` / `onboarding_completed` / `email_verified`
  fields on `GET /api/auth/me`. `complete_onboarding/1` had exactly one
  caller, the wizard LiveView, so an account configured entirely through the
  API stayed permanently un-onboarded and a later browser visit dropped the
  user into a wizard they had no reason to see (#525)

- **`GET /api/audit`** serves the account's own audit trail — tenant-scoped,
  newest first, cursor-paginated, with filters the `/audit` LiveView does not
  have yet (`action_prefix`, `resource_type`, `since`, `until`). Programmatic
  access previously meant scraping a LiveView or requesting a whole account
  export, which is a poor fit for shipping events to a SIEM or an archive.
  `action_prefix` is matched as a literal, so a `%` filters to nothing rather
  than returning the entire trail, and a malformed `since`/`until` is a 400
  rather than a silently unfiltered response (#526)

- **Password and email changes work over a bearer token**:
  `POST /api/auth/password` and `POST /api/auth/email`. Both existed only as
  browser POSTs with session auth and CSRF, so an API-driven account could
  never rotate its own credentials. Both still require the current password —
  a stolen bearer token must not be enough — and sit behind the `full`-scope
  gate so a sandbox's per-conversation token cannot rotate the account
  password. A password change signs out browser sessions but does not revoke
  API keys, which is what it has always done; the response now says so
  (`sessions_invalidated`, `api_keys_revoked`) instead of leaving a caller
  rotating a leaked password to find out later (#521)

- **The auth email flows can be finished over the API.** An API consumer
  could start every one of them — register, resend-verification, forgot —
  and finish none: confirmation and reset were browser routes, so account
  activation required a browser round-trip. `POST /api/auth/verify`,
  `POST /api/auth/reset` and `POST /api/auth/email/confirm` accept the same
  tokens the emailed links carry, so a CLI can prompt "paste the code from
  your email". The links themselves still point at the browser pages.
  `verify` is idempotent and issues no session — an API client mints a key
  at `POST /api/auth/token` once the account is live — and every flow keeps
  the browser path's rate limits, single-use token semantics and audit
  events (#522)

- **Usage counts are in the resource read-model**: agents carry
  `conversation_count`, environments `secret_count` and `agent_count`, vaults
  `secret_count` — on the list *and* single-resource reads, so "is this
  environment in use / safe to delete" is one request instead of an N+1 the
  client assembles. The counting queries already existed for the UI and had
  no controller caller (#529)

- **The conversation read-model the UI has is now the one the API serves.**
  Conversation JSON gained `title`, `turn_count`, `last_active_at`,
  `last_read_at` and a computed `unread`; `GET /api/conversations` takes
  `?roots_only=true` (the context supported it, no caller passed it);
  `POST /api/conversations/:id/read` marks one read; and
  `GET /api/conversations/:id/tree` returns the whole spawn tree —
  ancestors and descendants — so an agent that fanned out can enumerate its
  own sub-conversations instead of keeping client-side bookkeeping.
  `GET /api/conversations/:id` now reports real counts rather than the
  struct defaults. The unread rule had three copies in the web layer and now
  has one, in the context (#520)

- **A conversation's log events are readable as JSON**, not only as an SSE
  stream: `GET /api/conversations/:id/events`, cursor-paginated
  (`?after=`, `?limit=`) with the same `?streams=` filter the stream takes.
  Draining history with `?wait=false` still returned `text/event-stream`, so
  anything fetching, archiving or analysing a conversation's output had to
  implement an event-stream parser for what is a paginated list read. Rows
  carry the same fields the stream sends plus each event's `id` — the same
  value the stream uses as `Last-Event-ID`, so a client can page through
  history and then attach the tail exactly where it stopped (#519)

- **Inference credentials can be set over the API**, so an account can be
  bootstrapped without ever opening a browser: `GET/PUT/DELETE
  /api/account/inference-credentials[/:provider]`. A conversation cannot run
  without one of these, and until now `put_credential` had exactly two
  callers — the settings LiveView and the onboarding wizard — which made a
  headless `register → configure → run` flow impossible. `PUT` runs the same
  provider ping the settings page does and reports the outcomes distinctly
  (422 rejected, 504 timed out, 502 unreachable) so a client knows whether to
  re-type or retry; `validate: false` stores without the ping. Values stay
  write-only, and the endpoints need a `full`-scoped key — a leaked
  per-conversation sprite token must not be able to swap the keys the account
  runs on. Both surfaces now emit `inference_credential.write` / `.delete`
  audit events (#518)

### Fixed

- **A runtime that dies at startup now fails its turn instead of orphaning
  it.** Writing the prompt to a command whose process had already stopped —
  what happens when the runtime exits before reading stdin, from a bad flag, a
  missing binary or an OOM kill — exited the conversation's own server rather
  than returning an error. The supervisor restarted it, the restart found the
  sandbox already `ready` and so reattached, and the turn was left hanging
  behind a `list_sessions` error that named nothing real. The turn now ends
  `failed` and the conversation returns to idle, ready for another prompt.
  Healthy runtimes never took this path — the claude runtime blocks on stdin —
  but fast-exiting ones did, and against a one-shot exec it was close to a
  coin flip (#603)

- **Deleting your account no longer leaves a hole in the record of it.** The
  request that deleted the account was itself audited on the way out — after
  the account row was gone — so the write referenced a user that no longer
  existed, was refused by the database, and was dropped. The account-deletion
  event itself was never affected, but the request beside it vanished. That
  row is now kept, attributed to nobody, which is where it was headed anyway:
  a deleted account's audit rows are anonymised rather than removed, so an
  insert landing a moment earlier would have ended up in exactly the same
  state. Nothing about what a deletion erases has changed (#590)

- **Secret and credential events are recorded in one place instead of five.**
  Writing an environment or vault secret was audited identically by both
  LiveView forms, both API endpoints and `fountain apply` — five copies of the
  same event that had to agree, on the most sensitive data in the system, with
  a sixth surface one forgotten call from silence. Password resets, password
  changes and email verification had the same shape across two controllers
  each. All of them now record inside the context, so every surface present
  and future leaves the same trail, and the guardrail test covers them (#593)

- **Suspending an account, changing its role or cap, and revoking a key are in
  the affected account's own audit trail.** These recorded only into the
  admin privilege trail, which the page a user actually reads never shows — so
  from their side the account changed state with no explanation. They record
  in the context now, like every other mutation, and the admin surfaces still
  write their own privilege row on top. A test enumerates every context
  mutation that must audit, so the next one to be added fails loudly instead
  of silently joining the gap list (#552)

- **Your subscription changing state is in your own audit trail now.** The
  billing context recorded nothing, so an account could move from active to
  cancelled, or from trialing to gated, and the person it happened to saw only
  the result. Admin-initiated changes did land in the privilege trail, but the
  page users actually read never showed that table. Every transition —
  Stripe-driven, operator-driven, or decided by the trial sweeper — now
  records both ends of the change plus which of those three moved it, because
  "cancelled" means something different depending on who did it. A sync that
  reasserts the status an account already had records nothing, so the real
  transitions stay findable (#550)

- **Starting, prompting, interrupting, stopping and deleting a conversation
  are audited from the browser too.** Like resource CRUD, these were recorded
  through `/api` and silent through the UI — where conversations are actually
  driven. They are also the spend-relevant actions in the product, since every
  conversation runs a sandbox, so the trail matters for a billing question as
  much as a security one. Prompt events record the byte size and image count
  and never the text: the trail says a prompt happened, not what it said. A
  conversation ended by sandbox reclamation is attributed to the reaper, so
  "why did my agent stop" has an answer that is not "no idea" (#545)

- **The audit trail can now account for its own shrinkage, and background
  workers no longer change your data anonymously.** The retention pruner
  deletes `audit_events` among other tables, so the trail could get shorter
  with nothing to say when or by how much; it now records one summary per run
  with per-table counts, written after the pruning so a shortened window
  cannot delete the record of the deletion. The sandbox reaper's expiries and
  stuck-sandbox releases, an export completing, failing or aging out, and the
  bulk trial backfill in the release task all record too, each attributed to
  the worker that did it. Previously "my sandbox vanished" and "I asked for my
  data and never heard back" had answers only in the server log (#551)

- **Saving an inference credential during onboarding is audited like saving
  one anywhere else.** BYO provider keys are secret material on par with
  environment and vault secrets, and the settings page and API already
  recorded every write — but the onboarding wizard, saving the same
  credential through the same code, recorded nothing. The recording moved
  into the context, so all three surfaces share it and a fourth cannot
  quietly miss it. The provider name is still the whole payload; the
  credential never reaches the trail (#546)

- **Signing up and signing out are in your audit trail.** Registration was
  recorded only for OAuth signups; the browser form and
  `POST /api/auth/register` both created accounts silently, the latter because
  it runs on a public pipeline with no audit plug. Logins were recorded and
  logouts were not, so the trail showed sessions opening and never closing. An
  account's trail now opens with its own creation, which also means a brand
  new account no longer shows an empty audit page (#544)

- **Creating, changing or deleting an agent, environment or vault is audited
  from the browser too.** These mutations were recorded when driven through
  `/api`, because a blanket plug on that pipeline caught every write, and
  recorded nothing at all when driven through the UI — the inverse of the
  secrets gap fixed earlier, and backwards for the surface where most of this
  work actually happens. Someone reviewing their own trail saw an account
  where resources appeared and vanished with no explanation. The audit moves
  into the context functions, so the UI, the API, the onboarding wizard and
  `fountain apply` all leave the same record, and update events name the
  fields that moved — never their values (#543)

- **Minting an API key always leaves an audit trail now, whichever door you
  came through.** There are four ways to get a key, and `POST /api/auth/token`
  — the one that exchanges a password for a full-scope key, and the most
  attack-relevant of them — was the only one that minted silently, because it
  runs on a public pipeline that carries no audit plug. Anyone auditing "who
  issued a key and when" saw the UI and `POST /api/auth/api-keys` but not the
  CLI login door. The audit moves into `Accounts.create_api_key/3`, which
  every mint already goes through, so UI, API, CLI and the per-conversation
  callback rotation are covered by construction and a future surface gets it
  for free. Events carry the key's name, scopes and public prefix — enough to
  match a trail row to a listed key — and never the key (#542)

- **Email verification is now enforced where identity is established, not at
  each door.** #533 moved unverified logins onto a waiting page but left the
  check inside the LiveView hook, so it held only because every entry point
  remembered it — four of them on the API side alone. Two consequences were
  real: every controller route in the session pipeline (theme, avatars, export
  downloads, turn images, the credential POSTs) was reachable by an unverified
  session, and the bearer-token plug never checked verification at all, so a
  key minted before #314 closed `POST /api/auth/token` would still work
  forever. `TenantSessionAuth` now redirects such sessions to
  `/auth/verify-pending`, and `authenticate_api_key/1` refuses with 403
  `email_unverified` — the same status and reason the token endpoint gives
  when refusing to mint for that account. No key is affected in practice:
  across 163 unverified accounts, zero API keys have ever been issued (#533)

- **An unverified login no longer looks like a failed one.** Signing in with
  the right password but an unverified address issued a perfectly good session
  and then bounced it to `/auth/login` with "Please verify your email address"
  — so the user landed back on the form they had just used successfully, with
  nothing to say their session was fine and the resend path nowhere in sight.
  Worse, re-entering the password never helped: the verification link logs you
  in by itself. Those sessions now land on `/auth/verify-pending`, a page that
  names the address the link went to, offers a resend (same five-an-hour
  budget, keyed by account rather than IP) and a sign-out for anyone who typed
  the wrong address, and advances on its own the moment verification lands —
  in another tab or on a phone — with no second login. It cannot be camped on:
  a verified user hitting it is sent where they were going (#533)

- **Fetching a turn image over the API no longer fails when you ask for an
  image.** `GET /api/conversations/:id/turns/:turn_id/images/:position`
  returns PNG or JPEG bytes, but sat behind a JSON-only content-negotiation
  pipeline, so a client sending `Accept: image/png` — the natural header for
  the request — got `406 Not Acceptable` before the endpoint ran. It worked
  only if you asked for `*/*`, which is why browsers never hit it. The
  endpoint was also in no spec at all, while the `Turn` schema advertised
  `image_count`: the API told you two images existed and documented no way to
  reach them. Both fixed, and the endpoint is now in `/api/openapi.json` and
  `docs/api.md` (#578)

- **The `/api/auth/*` endpoints are now in the OpenAPI spec.** They never
  were: the spec is generated from the router, and a controller that does
  not declare operations is skipped in silence — so the published spec
  described every resource endpoint but not the one thing a client needs
  first, which is how to get a bearer token. `/api/docs` opened on a surface
  whose front door was invisible, and generated clients had to hand-roll
  authentication. All thirteen auth routes are documented now, with the seven
  public ones (`token`, `register`, `resend-verification`, `verify`, `forgot`,
  `reset`, `email/confirm`) declaring `security: []` so a generated client
  will actually call them without a credential it cannot yet have. A test
  walks the router and fails on any `/api/` route without an operation, so
  the gap cannot silently re-open (#571)

- **Secrets written through the API now leave the same audit trail as
  secrets written through the UI.** `POST/DELETE /api/environments/:id/secrets`,
  the vault equivalents, and the secret half of `POST /api/apply` recorded
  only the generic request row — so the trail could answer "who wrote a
  secret" only for people who used a browser, and the account export's
  `audit_trail` under-reported API-driven secret activity. All three paths
  now emit the same `environment.secret.write` / `vault.secret.write` (and
  `.delete`) events the LiveView forms do, carrying the key, never the
  value, and attributed to `api` or `sprite` as appropriate (#530)

- **The compose quick start no longer collides with a Postgres you already
  run.** The file published `5432:5432` unconditionally, which describes most
  machines evaluating Fountain — so the documented quick start failed on a
  developer workstation for a reason that had nothing to do with Fountain.
  The publish is host-side convenience only (the app reaches Postgres over the
  compose network), so it is now `${POSTGRES_HOST_PORT:-5432}:5432`: unchanged
  by default, and settable when 5432 is taken. CI also boots the pinned image
  against main's compose file on every run — the pairing a fresh `git clone &&
  docker compose up` actually gets, which nothing had been exercising, and
  which is how both #513 boot failures shipped (#549, #548)

## [0.5.2] — 2026-08-05

### Fixed

- The account-deletion warning on `/account` opened with "Cancels your
  subscription" on instances where billing is disabled and no subscription
  exists — the last billing reference the #513 fresh-machine sweep found on
  any surface. The clause now renders only when `BILLING_ENABLED=true`
  (#513, #569)

## [0.5.1] — 2026-08-05

### Fixed

- **The compose quick start still crash-looped on v0.5.0 — actually fixed
  now, verified by booting the built image through compose.** The #497/#541
  blank guards protect the config value, but the Sentry SDK also reads the
  `SENTRY_DSN` env var itself: `Sentry.Config.put_config/2` re-validates a
  partial keyword with no `:dsn` entry and `fill_in_from_env` injects the
  raw env value into it — and `Sentry.Application.start` calls `put_config`
  at boot, so the compose-supplied `SENTRY_DSN=""` crashed the `:sentry`
  application regardless of the config. A blank `SENTRY_DSN` is now deleted
  from the environment during config, before any application starts, so the
  SDK never sees it. Instances with a real DSN are unaffected (#513, #561)

## [0.5.0] — 2026-08-05

### Upgrade notes

- **Set `PUBLIC_URL` before upgrading.** Production now refuses to boot
  without it (or the deprecated `FOUNTAIN_DOMAIN`) — see below. The compose
  file and the `deploy/k8s` baseline already set it; anything hand-rolled
  from older docs may not.
- **With a real mail provider (Resend/SMTP), set `EMAIL_FROM`.** Also a boot
  requirement now. Instances on `EMAIL_DELIVERY=none` are unaffected.
- On billing-disabled instances, account export and deletion moved from
  `/account/billing` to `/account`, and accounts no longer carry
  trial/subscription state. If you later enable billing, the documented
  `expire_legacy_trials` release task is still the way to start trial clocks
  for pre-existing accounts.

### Added

- **`/terms` and `/privacy` render your legal identity, not the project's.**
  Set `LEGAL_ENTITY`, `LEGAL_CONTACT_EMAIL`, `LEGAL_JURISDICTION` and
  `LEGAL_EFFECTIVE_DATE` — all four or none; partially set refuses to boot.
  Unset, the pages are hidden and their links removed from signup and the
  footer, instead of rendering placeholder terms nobody agreed to
  (#506, #517, #534)

- Admin billing operations for the hosted service: Stripe webhook failures
  are persisted and surfaced on `/admin` instead of vanishing into logs
  (#501, #516); a user's subscription state can be force-resynced from
  Stripe (#502, #515); `/admin/users/:id` shows a read-only view of the
  user's Stripe invoices (#502, #539); dropped usage events emit telemetry
  (#503, #514); and a daily sweeper backstops stale `trialing` rows whose
  webhooks never arrived (#504, #512)

- The marketing homepage renders its price from `STRIPE_PRICE_MONTHLY_CENTS`
  instead of hardcoding the hosted instance's number (#500, #508)

### Changed

- **A billing-disabled instance no longer shows billing anywhere.** The
  Billing nav item, the admin dashboard's trial tiles, `trialing`
  filters/sorts and per-user trial controls all render only when
  `BILLING_ENABLED=true`; the core `/account` page owns export and account
  deletion (#479, #481, #491, #494). Accounts on billing-disabled instances
  are no longer stamped `trialing` at registration, and `/api/auth/me`
  reports `subscription_status: null` (#480, #496)

- Subscribers whose state is `past_due` or `canceled` keep read-only access
  to their conversations instead of a hard gate — they can read what they
  already ran, not start new work (#505, #538)

- **Two silent misconfigurations now refuse to boot in prod with actionable
  errors.** `PUBLIC_URL` is required (or the deprecated `FOUNTAIN_DOMAIN`) —
  the old `http://localhost:4000` fallback meant a prod instance ran fine
  while every verification/reset link and every sprite's `FOUNTAIN_BASE_URL`
  silently pointed at localhost. And `EMAIL_FROM` is required whenever a
  real delivery provider (Resend/SMTP) is configured — the old default was
  the hosted instance's sending domain, so an instance that didn't set it
  sent mail as someone else's domain, which providers checking SPF/DKIM
  reject anyway. With `EMAIL_DELIVERY=none`, `EMAIL_FROM` stays optional
  (nothing is sent) and falls back to a neutral `noreply@localhost`. The
  compose quick start and `deploy/k8s` baseline already set `PUBLIC_URL`,
  and instances that took the mail integration guide's advice to change
  `EMAIL_FROM` are unaffected (#495)

- The README no longer contradicts the licence story: it said nothing lived
  in `ee/` and that ee code would not be MIT — both false since #472. It now
  states what `ee/` holds (billing + growth mail) and that it is MIT today,
  a future-licence option only (decisions/0010). API examples run against
  `$FOUNTAIN_URL` instead of the hosted instance's domain, and the
  orchestrator "bus repo" framing moved out of the front door. Removed
  `PREREQUISITES.md` (stale instructions for the predecessor AoD stack) and
  `fly.toml` (an undocumented third deploy path with the hosted domains
  baked in) (#490)

### Fixed

- The self-host quick start pinned `v0.3.0` — an image from before the
  in-app first-login flow (#478), so following the docs verbatim dead-ended
  signup under `EMAIL_DELIVERY=none`. The compose and `deploy/k8s` pins now
  sit at `v0.4.1`, the release workflow bumps them inside every release
  commit, and a test fails any PR where a pin drifts from the released
  version. (#489)

- **The compose quick start no longer crash-loops on a fresh machine.**
  Compose interpolates unset `${VAR:-}` passthroughs to present-but-empty
  strings, and three reads in `runtime.exs` didn't survive that: the sandbox
  lifetime bounds hit the refusal written for typos (`Integer.parse("")`),
  `SENTRY_DSN=""` was handed to the Sentry SDK, which refuses to start, and
  `SPRITES_BASE_URL=""` displaced the default API endpoint so every
  conversation would fail at provision. Blank now means "not configured" and
  gets the default; a non-blank typo still refuses to boot. Found by running
  the fresh-machine walkthrough (#513) exactly as the docs write it
  (#497, #509, #541)

- Three documented variables were silently ignored under compose — set in
  `.env`, never passed to the app: `TRUSTED_PROXIES` (per-IP rate limits
  collapsed into one bucket behind a proxy), `SENTRY_DSN`, and
  `DATABASE_SSL_VERIFY`/`DATABASE_SSL_CA_FILE`. All pass through now
  (#397, #509)

- The CLI's built-in default `base_url` is the hosted instance, so on a
  self-hosted deployment the first unconfigured command sent the freshly
  minted API key to the hosted domain. The docs now call this out and lead
  with `FOUNTAIN_BASE_URL=... fountain auth login`, which records the URL in
  the saved profile (#510)

## [0.4.1] — 2026-08-05

### Upgrade notes

- Nothing breaking, and both new switches default off in the application. One
  default changed in the bundled compose file only: `docker-compose.yml` now
  sets `FIRST_USER_ADMIN=true` (see Added). If your compose instance
  deliberately has no admin, set `FIRST_USER_ADMIN=false` in `.env` before
  upgrading — otherwise the next account to become verified while no admin
  exists is promoted

### Added

- Self-host first login happens in-app (ADR 0011, #478). Under
  `EMAIL_DELIVERY=none`, accounts now self-verify at registration — a
  verification link that can never be delivered gates nothing — and the
  registration responses say "you can sign in now" instead of pointing at an
  inbox that will stay empty. With the new `FIRST_USER_ADMIN=true` (default
  off; the compose quickstart sets it), the first account to become verified
  on an instance with no admin is promoted, audit-recorded as
  `admin.role.granted` with a nil actor and `via: "first_user_admin"`. The
  grant fires on verification, not registration, so it always lands on a
  login-capable account, and concurrent first verifications are serialized so
  exactly one can win. `Fountain.Release.verify_email/1` and
  `promote_admin/1` remain as escape hatches for broken mail providers and
  lock-out recovery

### Changed

- Billing and all transactional email moved under a top-level `ee/` directory
  (#472), still compiled into the same application and still MIT — a
  future-license boundary, not a license change (decisions/0010). Module
  names are unchanged; a fork that deletes `ee/` loses billing and email, not
  auth or conversations

### Security

- The sobelow scan now covers web modules under `ee/lib` via a merged-tree
  script (#473), so the `ee/` move could not silently drop controllers out of
  the security scan's reach

## [0.4.0] — 2026-08-04

### Upgrade notes

- **`BILLING_ENABLED` now defaults to `false`** — the subscription gate is
  opt-in. An instance that relies on the gate must set `BILLING_ENABLED=true`
  explicitly before upgrading, or every account gets ungated access (the
  repo's hosted manifest under `k8s/` already sets it). See the #336 entry
  under Changed

- **A billing-enabled production instance now refuses to boot without
  `STRIPE_WEBHOOK_SECRET`** (#390). The webhook endpoint previously fell back
  to an empty signing secret, which is a signature anyone can forge, so the
  fallback is gone: set the secret, or leave `BILLING_ENABLED=false`. An
  instance with billing off is unaffected

- One migration adds a **unique** index on `users.stripe_customer_id`
  (#411), replacing the plain index. If a pre-upgrade instance has two
  accounts pointing at the same Stripe customer, the migration fails — resolve
  the duplicate before upgrading. Duplicates were themselves the bug: the
  webhook lookup raised and 500ed every delivery for that customer

- The compose quick start now pins an explicit image tag rather than tracking
  `latest` (#410). `.env.compose.example` ships the pin uncommented; an
  existing `.env` keeps whatever it already had, so set `FOUNTAIN_IMAGE_TAG`
  deliberately when you upgrade

### Added

- Point-in-time recovery for the hosted database (#209): continuous WAL
  archiving plus nightly base backups via the CNPG barman-cloud plugin into
  the existing Garage bucket, retention 14 days, RPO ~5 minutes with the
  nightly `pg_dump` kept as the operator-independent fallback. The dump job
  now sends a Sentry Crons check-in, so a backup that quietly stops running
  pages instead of rotting

- Accounts that register and never verify their email are deleted after 30
  days (#258) — they cannot log in, and 158 of them were briefly mistaken for
  a legacy trial cohort. Same teardown as self-serve deletion, Stripe
  cancellation included; `UNVERIFIED_PRUNE_AFTER_DAYS=0` disables,
  `UNVERIFIED_PRUNE_EXEMPT` protects deliberate unverified accounts

- Optional error tracking via Sentry (or any Sentry-API-compatible endpoint):
  crashes from every process — not just web requests — are reported with
  release correlation, rate-limited, with PII off. Fully inert unless
  `SENTRY_DSN` is set (#211)
- A portable Kubernetes baseline under `deploy/k8s/` — plain manifests,
  `kubectl apply -k`, no operators assumed; bring a Postgres and an ingress
  (#191)
- Dialyzer now gates CI and `mix precommit` (#236). Triage of its 77 findings
  fixed real bugs: OTel spans were ended by passing the span where a
  timestamp belongs (silently corrupting recorded spans), Stripe API params
  used strings where the client's specs say atoms, six schema modules never
  defined the `t()` their specs referenced, and `upsert_oauth_user`'s spec
  omitted the registration-refusal atoms — making dialyzer condemn the live
  controller branch handling them. Three understood warnings are pinned in
  `.dialyzer_ignore.exs` with reasons
- Transient Sprites API failures no longer fail provisioning outright:
  idempotent steps retry with bounded exponential backoff, sprite creation
  adopts an already-created sprite after a lost response, and the Sprites
  HTTP timeout is explicit and tunable (`SPRITES_TIMEOUT_MS`) (#168)
- Admin support tooling: subscription status, trial end and a Stripe dashboard
  link per user, trial extension (Stripe-aware), a `comped` status for
  operator-granted free access, per-user 30-day usage, and a sandbox reap
  action (#169). Admin account deletions are now actually audit-recorded —
  the event type was missing from the audit allowlist and failed validation
  silently

- An account security page at `/account/security` (#448): a logged-in user can
  finally change their password (previously only the logged-out
  forgot-password flow existed) and change their email address at all. Both
  are current-password gated; a password change ends every other session and
  keeps the current one, and an email change is confirmed by clicking a link
  sent to the new address — which also marks it verified — while the **old**
  address gets a notice, the tripwire for a takeover in progress. OAuth-only
  accounts see an explanation and a pointer at the reset flow instead of forms
- A working resend-verification path (#445): `GET`/`POST
  /auth/resend-verification` and `POST /api/auth/resend-verification`, rate
  limited and with the same fixed-response anti-enumeration contract as the
  password-reset request. The check-your-email page had linked to this route
  for some time and the link was dead. The verification email itself moved to
  a durable background job — it used to be an in-request task the finishing
  response could kill, and a dropped email was unrecoverable with no resend
  path
- A welcome email on the transition to a verified account (#449), sent once
  per user forever, so pre-existing verified accounts are never welcomed late
- Notification emails for the two account-state transitions that used to
  happen silently (#450): suspension and unsuspension (re-checked at send
  time, so a suspension lifted before the queue drained is not announced) and
  deletion, whose copy is honest about what survives — Stripe keeps invoices,
  backups age out on their own schedule. The billing page's danger zone now
  points at the export section before the destructive click, and the optional
  `SUPPORT_EMAIL` puts a real reply-to address in the copy when set
- Account suspension — an abuse lever between comping and deleting (#287):
  sessions are invalidated, active sandboxes are best-effort reaped,
  provisioning is refused at the door, and billing is deliberately untouched
  so webhooks keep syncing. Refusals are neutral and password-checked first,
  so login, OAuth and API keys never become an account-state oracle
- Self-serve data export (#288): a tenant-scoped export built by a background
  job, downloadable from the account page through an owner-scoped expiring
  link. Secret values are deliberately excluded — names only
- An admin per-user detail view at `/admin/users/:id` (#446) — billing state,
  resource counts, conversations, API key metadata (never key material), the
  user's own audit trail and every admin action taken against them — plus a
  metadata-only admin conversation view at `/admin/conversations/:id`, where
  prompts, outputs and log content deliberately never render. Both
  cross-tenant reads are themselves audited. Before this, an admin could
  suspend or delete a user but not look at one, and conversation links 404ed
  for every conversation the admin did not personally own
- Admin user table search, filtering, sorting and pagination, with the state
  in URL params so a refresh or an admin action preserves position (#285)
- An admin billing overview (#286): status counts, trials ending in the next
  seven days, conversions this month, MRR from active subscriptions ×
  `STRIPE_PRICE_MONTHLY_CENTS` (nil when unconfigured — no fabricated
  numbers), and the recent webhook events
- An admin lifecycle funnel (#282): registered → verified → onboarded →
  activated → subscribed with per-stage conversion and median timing, a
  stalled-user breakdown answering how far the verified-but-never-ran accounts
  actually got, and the same stages exported as Prometheus gauges
- Post-trial and payment-failure lifecycle emails (#283): `trial_expired`,
  `payment_failed` and `subscription_canceled`, enqueued from webhook status
  transitions, where an enqueue or delivery failure can never error the
  webhook
- First-class dunning: `invoice.payment_failed`,
  `invoice.payment_action_required` and `invoice.paid` are handled instead of
  everything being inferred from subscription updates (#447). The SCA email is
  new and leads with the fix; a new payment-recovered email fires on the
  `past_due` → `active` transition; and `invoice.paid` writes status in
  exactly one case — dunning recovery — so the $0 invoice Stripe pays at trial
  creation and at every renewal can never touch the account
- Self-serve subscription management (#284): `cancel_at_period_end` and
  `current_period_end` sync from webhooks and are cleared on resubscription,
  an "access until <date>" notice while a cancellation is pending, a direct
  billing-history portal link, and a guard that routes an existing customer
  with any live subscription to the Billing Portal rather than handing them a
  second, duplicate subscription
- `mix fountain.verify_lifecycle` (#289): a repeatable end-to-end billing
  check driven by Stripe Test Clocks — trial → T-3d email → expiry → paid
  subscribe → cancel-at-period-end → period end → re-subscribe → dunning →
  recovery — asserting Fountain-side state at every step. Test-mode keys only,
  with cleanup that runs even on failure. Documented as the release check for
  any billing-touching change
- `Fountain.Release.promote_admin/1` (#275): first-admin bootstrap without raw
  SQL, symmetrical with `verify_email/1`, audit-recorded and idempotent. Both
  deploy guides drop their SQL step
- A per-conversation durable log budget (#331): output stops being persisted
  at `LOG_OUTPUT_BUDGET_MB` (default 50 MB, `0` disables), with one truncation
  marker written at the crossing. Retention bounds age, not rate, and
  `log_events` shares the volume the database depends on, so a sandbox
  printing garbage was an availability risk. The counter is cumulative across
  wakes
- An absolute provision deadline (#329): a server stuck inside provisioning
  was invisible to every reclamation mechanism — the reaper skips rows whose
  server is alive, and the server's own timers queue behind the stuck
  callback — so the sandbox billed until the next deploy. An external watchdog
  now kills it at 30 minutes and applies the normal provision-failure
  transitions
- Substantially more operational visibility: conversation and sandbox gauges
  by status plus Oban queue depth and job outcome metrics with alerts (#321),
  provisioning and turn metrics rewired onto events that actually fire (#310),
  alerts on the cost signals that previously fired into nothing — leaked
  untracked sprites, platform-wide sandbox and conversation ceilings,
  provision deadlines (#405) — CNPG PITR backup alerting (#338), and
  rehydrator sweep telemetry (#408)
- A self-host observability pack (#277): a generic `PrometheusRule` with every
  alert commented with its meaning and action, and a 12-panel starter Grafana
  dashboard built only from metrics the app actually exports
- A backup and restore story for both deploy paths (#276): a profile-gated
  nightly `pg_dump` service for compose, a generic backup CronJob for
  `deploy/k8s` targeting any S3-compatible store, and the restore drill in
  `docs/operations.md` with the `MASTER_SECRETS_KEY` pairing rule stated
  loudly — a database restored without its matching master key cannot decrypt
  any secret
- Public documentation for the parts that had none: a system architecture page
  with failure domains and the life of a conversation (#273), an operations
  and troubleshooting guide (#278), one guide per third-party integration —
  Sprites, GitHub OAuth, Stripe, Sentry, mail — with the required/optional
  matrix up front (#274), the Sprites dependency contract as consumed (#279),
  and a complete runtime configuration reference where every variable
  `config/runtime.exs` reads is documented, enforced by a test in both
  directions (#292)
- `fountain keys list --json`, matching every other list command, and
  first-time documentation of the `op://`, `bws://` and `infisical://` secret
  resolvers (#410)

### Changed

- Self-host first-run papercuts (#336): the GitHub sign-in button only renders
  when `GITHUB_OAUTH_CLIENT_ID` is configured (clicking it unconfigured
  dead-ended on a GitHub error page); the compose `app` service now has a
  healthcheck against `/health`; `TRUSTED_PROXIES` is documented in the
  `deploy/k8s` baseline; and **`BILLING_ENABLED` now defaults to `false`** —
  the subscription gate is opt-in (breaking; see Upgrade notes above)

- With billing disabled, an instance stops performing billing (#335): signups
  no longer enqueue a Stripe customer sync that 401s through all five attempts
  — dead jobs and error noise a self-hoster has no way to know are benign —
  and the billing page says plainly that billing is disabled instead of
  showing a trial countdown and an Upgrade button whose only possible outcome
  was "Unable to reach Stripe"
- Trace export is off unless an export target is configured (#317). It
  defaulted to OTLP aimed at Honeycomb whenever the app ran in production, so
  the portable baseline — which sets no OTEL variables — shipped continuous
  rejected span batches to a third-party vendor. Setting
  `OTEL_EXPORTER_OTLP_ENDPOINT`, `HONEYCOMB_ENDPOINT` or `HONEYCOMB_API_KEY`
  switches it back on
- Every route to a sprite is now gated on billing and suspension, not just
  fresh provisioning (#313). Reattaching to a live sandbox provisioned
  nothing, so it never met a gate; and a running conversation outlived the
  subscription state it started under, where every turn reset the idle clock —
  a trial that expired at minute one could buy up to 24 hours of continued
  service. The gate now also runs per turn, whichever door the prompt came in
  by
- The published OpenAPI spec describes this product (#423): it still called
  itself "Agent on Demand", pointed at the `aod` CLI and told integrators to
  authenticate with the `ADMIN_TOKEN` mechanism deleted two phases ago. It now
  names Fountain, the `fountain` CLI and per-user API keys, and the error
  table documents the `402` and `410` responses the API has been returning all
  along. The Conversation schema also drops an unreachable `completed` status
  and gains the `source` and `parent_conversation_id` fields it has been
  emitting, both now pinned by a drift test (#415)
- The production image is built on the same Elixir and OTP the test suite runs
  against (#425). The Dockerfile had drifted to a higher Elixir and a *lower*
  OTP than `.tool-versions` and CI; a test now fails if the three pins ever
  disagree again
- `k8s/` became a kustomize overlay of the portable `deploy/k8s` baseline
  (#264), so probes, security context, resources and rollout strategy exist
  once; the hosted overlay keeps only what is genuinely personal
- Deploys became less able to surprise: image builds trigger on a *successful*
  CI run rather than independently on push (#333), the manifest publish is
  gated by a `kustomize build` + `kubeconform -strict` + `promtool` validation
  job over both manifest trees (#414), the image-pin substitution is verified
  rather than assumed, and CI cancel-in-progress is now PR-only so a rapid
  merge cannot cancel another commit's build out from under it
- Rollouts drain properly (#408): a 120-second termination grace period and a
  preStop delay in the shared deployment base, plus a PodDisruptionBudget
  wired into the hosted manifests (shipped commented out in the portable base,
  where the 1-replica default would block drains)
- Container images are built natively per architecture instead of emulating
  arm64 under QEMU, with a registry layer cache (#361) — the same images,
  roughly 20 minutes sooner
- Manifests are published as an OCI artifact, and the `deploy` git branch that
  previously carried them is retired (#301, #303); rollback is now
  `flux tag artifact ... --tag latest` against an older `sha-` tag, documented
  in the workflow header
- `mix precommit` matches CI more closely: Credo no longer runs with
  `--mute-exit-status` (#333), sobelow was moved to where it actually scans a
  Phoenix app — at the umbrella root it detected nothing and exited 0, so the
  gate had scanned nothing since it was added — and now runs locally too
  (#311), and its threshold was lowered to the confidence level this codebase's
  entire XSS surface is reported at, with each of the 11 findings individually
  reviewed and justified in place (#414)

### Fixed

- A conversation's very first prompt could vanish (#367). It was cast through
  the distributed registry immediately after the server started, and a
  registration that has not yet propagated makes the cast a silent no-op: the
  API returned 201, provisioning succeeded, and zero turns ever ran. The cast
  now targets the pid directly
- Prompt, interrupt and terminate no longer 500 against a conversation that is
  still provisioning (#412). A blocked server means the call *exits* rather
  than returning an error tuple, and none of the seven call sites caught it;
  worst case was `DELETE`, where the 500 masked a delete that silently never
  ran. Callers now get a `503` with `Retry-After`, and the delete goes through
- A sprite WebSocket that dropped mid-turn left the turn "running" forever
  (#413): every further prompt answered "busy", idle reclaim was suppressed,
  the reaper skipped the sandbox, and the sprite billed until its 24-hour
  maximum lifetime. A dropped socket now fails the turn and returns the
  conversation to idle, the same shape as a non-zero exit
- The SSE stream now tells a client when the server behind it dies (#415)
  instead of sending heartbeats forever on a topic nothing will publish to
  again; a client disconnecting mid-replay no longer produces a crash report
  and a Sentry event per interrupted `curl`; and a spawn that never starts
  resets the conversation from `running` back to `idle`
- The provision watchdog now fails the database rows *before* killing the
  stuck server (#394). Killing first let the supervisor restart it into
  provisioning while the row still said pending — usually winning that race,
  provisioning a second billable sprite, and leaving a live server streaming
  into a sandbox whose row said terminal
- Concurrent requests can no longer exceed the per-tenant sandbox cap (#330):
  the quota check and the row insert now happen in one transaction under a
  per-user advisory lock. Separately, when two wakes of the same conversation
  raced, the loser stranded a pending row holding a quota slot until the
  reaper's next pass an hour later — a user at their cap could lock themselves
  out by double-clicking. The loser now cleans up and forwards its prompt to
  the winner
- Stripe webhooks whose apply failed are no longer lost (#312). The claim was
  written before the apply and outside any transaction, so the 500 that asks
  Stripe to redeliver was answered by a redelivery that deduped against the
  claim and did nothing. Claim and apply now share a transaction
- Webhook sync is keyed by the subscription of record, not the customer
  (#309). Upgrading mid-trial creates a second Stripe subscription, and events
  from either one wrote the same account — so Stripe cancelling the abandoned
  trial subscription locked out a customer who was paying on the other one.
  Checkout completion now cancels the other live subscriptions, and events for
  anything but the subscription of record never touch the account
- Webhook sync guards are evaluated under a row lock (#393), closing a window
  where a `customer.subscription.deleted` could read a user mid-upgrade,
  before the checkout transaction committed, and land its update afterwards —
  marking a just-paid customer canceled. The Stripe cancellation calls also
  moved out of that transaction, so no database lock is ever held across
  third-party HTTP
- An operator's trial extension outranks in-flight webhooks (#334): the
  extension now advances the sync watermark, so a straggler event from an old
  subscription can no longer silently revert the decision and re-gate the user
- Trial subscriptions are actually created at signup (#351). Two halves of the
  design cancelled each other — registration stamps a local trial end on every
  account, and the worker only opened a Stripe subscription when that field
  was nil — so no signup ever got one: no trial-ending warning, no cancellation
  at trial end, and nothing for the trial-expired email to hang off. The
  subscription now anchors to the locally-stamped date rather than restarting
  the clock
- Trial creation is idempotent (#400). Stripe statuses the changeset rejects
  made the write fail, the retry guard checked a field the failed write never
  set, and each of up to five retries created another subscription — all of
  which converted when the user later added a card. Statuses now go through
  the same coercion the webhook uses, and creation carries a stable
  per-user idempotency key
- A comped account is never offered Checkout (#399). Comping cancels every
  live subscription, so the billing page read a comped account as a fresh
  customer, showed Upgrade, opened Checkout and took the money — after which
  webhook adoption dropped the subscription id on the floor, making a paying
  customer invisible and locking them out when the comp was revoked
- The two usage numbers on the billing page no longer diverge for exactly the
  accounts whose provisioning is failing (#411): a sandbox that dies before
  reaching ready now emits its own usage event, counted by both summaries
- `docker compose up -d postgres` works on a fresh clone (#392). Compose
  interpolates the whole file regardless of which service you target, so the
  required-variable syntax on the app service aborted the documented
  database-only path — the very first command in `SETUP.md` — with an error
  about a service the contributor never asked to start
- Compose-style empty strings are treated as unset (#426). Passing optional
  variables as `${VAR:-}` makes them present-but-empty, and an empty string is
  truthy in Elixir, so every unset-guard written for these variables failed to
  fire: `RESEND_API_KEY=""` selected the Resend adapter and POSTed every
  verification and reset email — recipient address and live signed URL — to
  Resend to be 401'd, making the stock compose configuration's mail path
  unreachable; `SMTP_USERNAME=""` forced authentication with an empty
  username; and `SPRITES_TOKEN=""` defeated its own missing-token guard and
  turned a helpful message into an opaque 401
- `.env.compose.example` no longer advertises variables compose silently
  ignores (#410) — a new drift test immediately caught five, including
  `SPRITES_BASE_URL` and `REGISTRATION_ALLOWED_EMAIL_DOMAINS`
- LiveView pages reconcile state they used to load once at mount (#401): the
  conversation log viewer subscribed to a topic nothing publishes on, so live
  log events never arrived; the conversation header froze at its mount-time
  status instead of tracking the run; six delete handlers crashed on a row
  deleted in another tab instead of flashing; mid-session refusals show real
  messages instead of a raw atom; and `idle` — the resting state of every
  healthy conversation — gets the healthy badge colour instead of the
  unknown-value grey
- The API prompts endpoint maps every refusal to a 4xx (#332). Three known
  error shapes 500ed — the fourth time an unhandled shape hit this
  hand-maintained clause — and unmapped future ones now become a logged 422
  rather than a blank 500
- CLI: `keys create` decoded an envelope the server does not send, losing the
  plaintext key it had just minted; `conv prompt`/`stream` replayed full
  history and exited on the first *prior* turn's completion; and a failed turn
  exited 0 (#398). Provisioning and setup output is no longer silently
  dropped, so a failing `apt install` or `git clone` is visible, and server
  errors render as messages rather than raw Go map dumps (#410)
- Telemetry no longer dies for the lifetime of the pod after a single blip
  (#365, #395). The poller permanently drops a measurement whose tick fails,
  and the first collection fires while the database pool is still starting —
  verified on both production pods, where the funnel gauges were never
  recorded at all. The guards now cover raises, exits and throws, and the next
  tick retries
- The leaked-sprite metric was a level reported as a counter (#405), so a
  steady 102 untracked sprites read as 2,448 after a day and climbed forever
- Rate-limit buckets are swept every 10 minutes (#326). The table grew one row
  per distinct bucket and IP since boot — unbounded, and invisible until an
  instance stayed up long enough or someone walked an IPv6 range
- Unbounded growth elsewhere (#408): `log_events` gets the `inserted_at` index
  its nightly prune needs, expired export payloads are purged every run rather
  than only when someone requests another export, and expired API keys are
  pruned even when nothing revoked them
- Conversation server lifecycle races (#408): callback-key revocation now acts
  only on the key that server itself minted, so a rotation cannot revoke a
  live duplicate's credential under registry lag, and the supervisor has its
  own restart budget instead of sharing the default 3-in-5-seconds across
  every conversation on the node
- An admin event type missing from the audit allowlist no longer disappears
  silently (#451). It has happened twice; rejections now log at error level
  and emit a telemetry counter, and a static test scans for admin event
  literals that are missing from the list, so the mistake surfaces during
  development instead of as a hole in the privilege trail
- Client IP resolution behind the tunnel (#300): the endpoint listens on
  `[::]`, so IPv4 peers arrive as IPv4-mapped IPv6 addresses that never match
  a v4 CIDR — the trusted-proxy gate failed on every request and every
  rate-limit bucket and audit row keyed on the node gateway
- Release tasks run in production (#256): they used to boot the whole
  application, which beside a running server dies on `eaddrinuse` and would
  otherwise start Oban and the distributed registry on a throwaway node
  competing with the real cluster. The OpenAPI export job now migrates before
  booting (#255), and the release job downloads only the artifacts it ships
  (#257)

### Security

- The Stripe webhook endpoint fails closed when no signing secret is
  configured (#390). It resolved the secret from a key nothing sets and fell
  back to an empty string, so on every instance that never configured billing
  the signature check was an HMAC keyed on `""` — which anyone can compute,
  giving unauthenticated write access to subscription state through forged
  events. Requests are now rejected outright when the secret is missing (see
  Upgrade notes)
- The tenant data-encryption key is no longer held in LiveView assigns
  (#391). The environment and vault secret forms unwrapped the key at mount
  and kept it in process state with the in-flight plaintext secret beside it,
  reassigned on every keystroke — and LiveView crash reports dump channel
  state to the logger and to Sentry, so any unhandled exception leaked the key
  that decrypts the tenant's entire secret set. The key is now loaded inside
  the handler and the form is uncontrolled, so neither ever enters assigns
- Conversation server state is redacted from crash reports (#315). It holds
  plaintext sprite environment values, the raw tenant key, decrypted
  bring-your-own inference credentials, the sprite callback key and the
  platform Sprites token; a probe crash was verified to print every one of
  them before the fix
- Request bodies are scrubbed by shape, not by name, before reaching Sentry
  (#402). The SDK default is an exact-name denylist, so the secret-write
  endpoints' `value` field and a manifest apply's whole `spec.secrets` map
  arrived as plaintext whenever an exception fired mid-request. Every string
  value now becomes a length tag, which covers the next secret-bearing
  endpoint by default
- Password-reset tokens are single-use (#325). A used token stayed live for
  the rest of its hour and could re-reset the password from a shared inbox,
  forwarded mail or a proxy log. Legacy tokens issued before the upgrade fail
  closed and die out within one hour of deploy
- Agent output is no longer an XSS vector, and browser routes carry a Content
  Security Policy (#323). Worse than filed: the markdown renderer escapes
  *inline* raw HTML but passed *block-level* raw HTML through verbatim, so
  agent output containing an `<img onerror=...>` as its own paragraph was live
  XSS rather than a `javascript:` link behind a click. Rendering now goes
  through the AST with verbatim nodes escaped and link schemes filtered after
  entity and whitespace normalization
- An agent can only attach an environment owned by the same tenant (#308).
  The error deliberately mirrors a nonexistent id, so a foreign environment
  cannot be confirmed by probing, and the conversation server loads the
  environment scoped by owner as a second layer — a legacy cross-tenant row
  provisions without it rather than materialising another tenant's secrets and
  checkpoint into the attacker's sprite
- Password login against an OAuth-only account returns `401` instead of `500`
  (#324). Verifying against a nil password hash raised, which was a
  Sentry-flooding crash and an account-existence oracle in one, defeating the
  anti-enumeration work everywhere else. The nil case now burns the same
  constant-time comparison as the no-user branch
- `/api` is rate limited before authentication (#316), so failed authentication
  is metered. The auth plug halted with a 401 before the limiter ever ran, so
  anonymous callers had unlimited attempts, each costing a hash and an indexed
  lookup
- Minting an API key requires a verified email (#314). Verification was
  enforced in the browser hooks only, so register → token → create agent →
  provision worked without ever touching an inbox. Separately, an account
  whose trial end is missing now fails closed unless it predates the legacy
  backfill
- Avatar uploads are validated against the same media-type allowlist as turn
  images and re-checked at serve time behind `nosniff` and a sandboxing CSP
  (#407) — the upload widget's `accept` list does not constrain what gets
  stored, so a crafted client could store `text/html` and have it served from
  the application's own origin. The conversation LiveView also stopped
  decoding raw client base64 with a raising call that crashed the process, and
  the LiveView socket has an explicit maximum frame size instead of Phoenix's
  unlimited default
- Audit rows recorded from LiveView resolve the client IP the same way the API
  does (#407), instead of trusting the leftmost, client-supplied entry in
  `X-Forwarded-For`
- The sprite callback token is revoked on supervisor shutdown (#322). The
  server never trapped exits, so its teardown skipped the most common
  teardown there is — application shutdown and rebalances, i.e. every deploy —
  leaving a live sprite-scoped tenant credential outstanding until its 30-day
  expiry
- Every unscoped context function now carries the `_unsafe_` prefix (#328,
  #407), so a reader of a call site never has to go and find out whether
  tenant scoping applied; the dead unscoped surface was deleted outright. A
  custom Credo check enforces that each `_unsafe_` call site names what
  established ownership on that path

### Removed

- SSH repository clones (#228). Implemented and hardened but unreachable —
  validation has required `https://` since the schema existed, and production
  confirmed zero use. Private repos are covered by https + token secrets; the
  implementation stays in git history if demand appears
- The legacy single-tenant admin login (#327): `POST /login` read a token set
  only in test config, so in production the public route's failure mode was a
  500, and the login form it belonged to could never succeed. Real admin
  authentication is the `require_admin` hook. The four legacy routes, two
  unused auth plugs and their test scaffolding are gone
- The `deploy` git branch (#303) — the OCI manifest artifact is now the only
  deploy target
- `render.yaml` and the home-cloud cutover runbook (#409): production has been
  Kubernetes since the cutover, and both documents still asserted a deployment
  that no longer exists. `STRIPE_PUBLISHABLE_KEY`, read by nothing, is gone
  from `.env.example` (#292)

## [0.3.0] — 2026-08-02

### Upgrade notes

- Set `PUBLIC_URL` to your external URL, scheme included. It is now separate
  from `PHX_HOST` and is what generated links, OAuth callbacks, and sandbox
  callbacks are built from (#204). An `https://` `PUBLIC_URL` also switches on
  the HTTPS redirect, HSTS, and secure session cookies (#241) — if you
  terminate TLS in front of Fountain, your proxy must set `X-Forwarded-Proto`.
- Production now refuses to boot without a mail setting. Configure
  `RESEND_API_KEY`, `SMTP_HOST`, or explicitly opt out with
  `EMAIL_DELIVERY=none` (#223).
- Migrations continue to run automatically at boot; no manual steps.

### Added

- Bulk manifest apply — a whole manifest in one request, and the CLI's
  `fountain apply` uses it (#151)
- Agent-scoped vault allowlists: an agent can be restricted to a named set of
  vaults (#144)
- `networking_config` on Environment, typed and documented (#146)
- `metadata` field on Environment and Vault for external tooling (#145)
- `GET /api/auth/api-keys` — list active keys, metadata only (#143)
- GitHub-sourced agent skills require a ref/SHA pin (#149)
- Account deletion, self-serve and admin (#234)
- Billing that holds: real Stripe trial subscriptions with end dates (#244), a
  warning email three days before a trial ends (#251), usage events (#213),
  idempotent order-aware webhooks (#214), and billing gates on every
  provisioning path (#212)
- Sandbox lifecycle bounds: per-tenant concurrent-sandbox cap (#205), idle
  timeout and maximum age (#233), and a reaper for leaked sprites and rows
  stuck mid-provision (#232)
- Durable job queue (#217)
- Self-hosting support: compose file and guide (#225), configurable
  `SPRITES_BASE_URL` (#189), database TLS / billing / registration switches
  (#224), SMTP delivery (#223), split liveness and readiness probes (#230),
  and an explicit MIT licence (#226)
- LLM-generated conversation titles, agent avatars, unread indicators, and a
  live-updating sidebar
- Public documentation site (MkDocs); OTel instrumentation for the
  conversation lifecycle (#125); Prometheus/Loki/Alertmanager wiring for the
  hosted instance (#210)
- Context-level and property-based test suites, with coverage held above a CI
  floor

### Changed

- Agent, environment, and vault editors use structured form UI instead of raw
  JSON textareas (#122–#124)
- Sandboxes are named `fountain-<tenant>-<id>` (#70)
- The hosted instance runs two clustered replicas (#132), with a single
  elected leader for conversation rehydration (#133)
- CI actually gates: strict Credo, coverage floor, sobelow, secret scanning,
  CLI tests on release (#237), and a smoke test that boots the built image
  against its own health probes (#249)
- Deploys pin the exact built image on a dedicated `deploy` branch so manifest
  and image can never diverge (#250)

### Fixed

- Conversations no longer replay their last prompt on every deploy (#248)
- The SSE stream endpoint no longer 406s real clients (#229), and the CLI
  resumes a dropped stream instead of reporting success (#219)
- `force_ssl` is applied as a runtime plug (#243), with health probes exempt
  from the HTTPS redirect (#245)
- Paid checkouts are never orphaned (#212)
- Turn images are validated at ingest, not only on serve (#235)
- `agents.skills` migrated from `text[]` to `jsonb[]` (#65)
- `PasswordResetController` returns `422 Unprocessable Entity` (was `200 OK`)
  on validation failure

### Security

- HSTS, secure cookies, and a scoped `check_origin`, all derived from
  `PUBLIC_URL` (#241)
- OAuth identities require a provider-verified email before linking (#240)
- Tenant secrets are redacted from sprite output before it is persisted (#222)
- Real client IP resolution behind proxies, and rate-limited login forms
  (#216)
- Tenant scoping tightened across the conversation spawn graph (#215), turn
  images (#202), sprite callback tokens — now with key expiry (#206), audit
  events (#68), and per-conversation `FOUNTAIN_TOKEN`s scoped to their owner
  (#75)
- Provisioning hardening: `.env` values quoted inertly (#227)
- Audit coverage extended to the browser surface, auth events, and admin
  actions (#221); external audit findings addressed (#129, #130)

## [0.2.1] — 2026-05-10

### Fixed

- CLI defaults its base URL to `fountain.inevitable.fyi` (#62)
- Dashboard "Recent conversations" card links to `/conversations`

## [0.2.0] — 2026-05-10

### Added

- Public marketing landing page at `/`
- Cross-tenant security regression suite (#55)

### Changed

- CLI ported from Elixir/Burrito to Go; the Elixir CLI and its release
  pipeline are removed (#60, #47, #50)
- Unscoped context functions renamed `_unsafe_*` as an enforcement convention
  (#54)

### Fixed

- Postgres `$N` placeholders in recursive CTE queries (#58)
- `fountain apply` strips ownership fields before POST/PUT (#59)

### Security

- Agent, Environment, Secret, and Vault controllers scoped to the
  authenticated user (#49, #51, #52); `user_id` propagated through
  `start_conversation` and orphaned rows backfilled (#48)

## [0.1.0] — 2026-04-01

### Added

- Multi-tenant API and UI for managing Agents, Environments, Vaults, and Conversations
- GitHub OAuth login via Ueberauth
- Stripe billing integration with subscription enforcement
- Per-tenant envelope encryption for secrets (AES-256-GCM, per-tenant DEK)
- Sprites sandbox platform integration (spawn / poll / stream log events)
- LiveView UI: dashboard, agent editor, environment/vault editors, conversation viewer, admin panel
- REST API with API-key authentication and per-tenant rate limiting
- `fountain` CLI (`cli/`) with `auth`, `apply`, `get`, `describe`, `delete` commands
- `llms.txt` / `llms-full.txt` / `/skill` endpoints for LLM-native API discovery
- Audit log for state-changing actions (append-only, best-effort)
- Substitution engine for `${VAR}` / `$$` interpolation in agent configs

[0.7.0]: https://github.com/BinaryBourbon/fountain/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/BinaryBourbon/fountain/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/BinaryBourbon/fountain/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/BinaryBourbon/fountain/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/BinaryBourbon/fountain/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/BinaryBourbon/fountain/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/BinaryBourbon/fountain/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/BinaryBourbon/fountain/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/BinaryBourbon/fountain/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/BinaryBourbon/fountain/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/BinaryBourbon/fountain/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/BinaryBourbon/fountain/releases/tag/v0.1.0
