# Architecture

This page is the system view. It says what processes exist, what each one
talks to, and what breaks when a dependency is down. For the domain objects,
which are agents, environments, vaults and conversations, read
[The four primitives](primitives.md).

---

## The runtime shape

Fountain is **one OTP release**, `fountain_server`. Everything below runs in a
single BEAM instance. There is no separate worker deployment and there is no
sidecar. To scale out is to run more replicas of the same image.

| Piece | Job |
|---|---|
| **Phoenix endpoint** | The one public listener. It serves the operator console, the REST API and the SSE streams, on one port. |
| **Conversation server** | One process for each active conversation. It owns the sandbox. It provisions the sandbox, spawns a turn in it, streams the output back, and enforces the lifecycle bounds. It holds the decrypted tenant key in memory while it lives. Fountain registers it across the cluster, so exactly one exists for each conversation, whatever the replica count. |
| **Rehydrator** | Runs once at boot. It finds the conversations that were live before the restart and starts their servers again. Those servers reattach to the sprite, which still runs, so a deploy kills no work. |
| **Oban** | Background jobs, which are the credit pricer and expirer, the credit emails and the account exports on the `exports` queue. It also runs the cron schedule below. |
| **Metrics listener** | A second, private HTTP listener on `METRICS_PORT`, which is 9568 in production and off elsewhere. It serves `/metrics` and `/health`. It is deliberately apart from the public endpoint, so that no ingress rule can expose it by accident. |

Here is the scheduled work. All times are UTC.

| Schedule | Job | What it does |
|---|---|---|
| Each hour at :07 | The sandbox reaper. | Reconciles the sandbox rows against sprites.dev. It frees a row stuck mid-provision, expires an abandoned sandbox, destroys a sprite whose row is already terminal, and reports an untracked sprite. |
| 04:23 daily | The retention pruner. | Deletes a row past its retention. Log events and Stripe events go after 90 days, audit events after 365, and usage events after 400. A revoked API key or a finished sandbox request goes after 30. |
| 05:41 daily | The unverified-account pruner. | Deletes an account that never verified its email, after 30 days, through the full deletion path. That covers sprites and audit. |
| Each 5 minutes | The sandbox queue drainer. | Replays work that waits for sandbox capacity, and expires a request past its wait bound. A freed sandbox slot drains the queue at once; this run is the backstop. |
| Each 10 minutes | The credit pricer. | Burns each closed turn into the credit ledger, and sweeps each expired grant. |
| 06:23 daily | The credit expirer. | Sweeps each expired grant. It is a backstop for the pricer. |

### Clustering

One replica needs none of this. With more than one, the replicas must form an
Erlang cluster, and `CLUSTER_DNS_QUERY` must point at a headless service.
[Run more than one replica](guides/operate/kubernetes.md#run-more-than-one-replica)
lists the env that wires it. Two things depend on it.

- The conversation registry places each conversation server on exactly one
  node, and finds it from any node.
- PubSub fans a conversation's events out to whichever replica holds the
  viewer's websocket or SSE connection.

Two replicas that never clustered form two islands. A conversation spawns
without trouble, and the stream breaks without a sound for a viewer connected
to the other replica.

The scheduled jobs elect one leader, whatever the replica count. The
rehydration sweep at boot waits for cluster membership to settle, then runs on
one node alone.

---

## Where state lives

**Postgres is the only durable store.** Users, agent and environment configs,
encrypted secrets, conversations, turns, log output, the audit trail, the job
queue and uploaded images are all rows. A sandbox is disposable by design, and
Fountain persists the output as it streams. So to destroy a sandbox loses
nothing that mattered.

Two things are deliberately *not* durable.

- The in-memory tables on each node. Those are the rate-limit counters and the
  log-redaction registry. Fountain rebuilds them empty at boot.
- The memory of one conversation. The decrypted tenant key, the inference
  credentials, and the sandbox's callback token live in that conversation's
  process alone, and die with it.

A complete backup is therefore **Postgres plus `MASTER_SECRETS_KEY`**. Nothing
else holds state. [The secrets model](#the-secrets-model) below explains why
the key is half of that sentence.

---

## Dependencies and failure domains

| Dependency | Needed for | When it is down |
|---|---|---|
| **Postgres** | Everything. | `GET /health/ready` returns 503, and a load balancer drains the instance. The app stays up and does not restart, because a restart does not fix Postgres. That is why [the restart check deliberately checks nothing](guides/operate/observability.md#health-endpoints). Recovery happens on its own. A replica that *boots* against a database that is down fails instead, because migrations run at boot. |
| **sprites.dev** | Conversations. | A new provision and a wake both fail, after bounded retries with backoff. Fountain then marks the conversation `failed`, or leaves it resumable if it was a wake. Everything else still works, which is sign-in, dashboards, agent, environment and vault management, and past logs. Readiness deliberately leaves it out, because a third party's uptime does not belong on the request path. |
| **Stripe** | Payment for credit packs, which is optional under `CREDITS_ENABLED`. | Checkout fails with a visible error. The account page itself still renders, from local state. Stripe delivers a webhook again until Fountain acknowledges it. Fountain expires the opening credit against the local clock, so an outage delays a purchase and does not open the gate. |
| **Mail**, from Resend or SMTP. | Signup verification, and password reset. | Both dead-end while the provider is down. The escape hatch is `Fountain.Release.verify_email/1`. Read [Email](guides/operate/email.md). `EMAIL_DELIVERY=none` is a different thing, because an account then self-verifies (ADR 0011). |
| **GitHub OAuth** | The OAuth login button, which is optional. | That button, and nothing else. Email and password auth still works. |
| **Sentry** | Error reports, which are optional. | It is inert without a DSN, and nothing depends on it. |
| **Object storage** | Database backups, at the ops layer. | The application never touches object storage. It exists in a deployment's backup pipeline alone. |
| **Inference providers** | Turns. | The credentials belong to one user. Fountain stores them, and the sandbox consumes them. An Anthropic or OpenAI outage fails a turn, and not Fountain. |

---

## The secrets model

This is envelope encryption, in two layers.

1. Each tenant has a **data encryption key**, a DEK. Fountain encrypts each
   environment and vault secret with it, under AES-256-GCM.
2. Fountain stores the DEK itself **wrapped** by `MASTER_SECRETS_KEY`. That is
   an environment variable, and Fountain never writes it to the database.

Three results follow from that layout.

- **A database backup cannot decrypt itself.** To restore the secrets you need
  the same `MASTER_SECRETS_KEY` that was live when somebody took the backup.
  So
  [keep it apart from the backups](guides/operate/back-up-and-restore.md#back-master_secrets_key-up).
- Lose the master key, or change it, and you lose each stored secret. Nothing
  else goes, because accounts, configs and history are plain rows.
- An attacker with database access alone holds ciphertext and wrapped keys.
  They hold no value.

At spawn, a conversation's server loads its tenant's DEK into memory. It
decrypts the environment secrets, then the vault secrets, and **the vault wins
on a key collision**. It resolves the `${VAR}` references in the agent's MCP
config. It registers each value with the log redactor *before the first line
of log*. It then hands the values to the sandbox, as the process env, and as
an env file with `chmod 600`.

The DEK never leaves that process, and Fountain discards it when the process
stops. The API is write-only throughout, and it never returns a stored value.

---

## A conversation's life

Fountain records progress as **stage events**. The stage names below are the
exact strings that the UI, the SSE stream and the log rows show. Each carries
a state of `started`, `done`, `failed` or `interrupted`.

1. **Gates.** A prompt arrives, through `POST /api/conversations` or through a
   client on it. Four gates apply, in order. The agent must exist *and belong
   to you*, because Fountain scopes each query in the system to one tenant.
   The vault must be on the agent's allowlist. The credit gate applies when
   `CREDITS_ENABLED` is on, and answers `402` at a zero balance. The quota for
   concurrent sandboxes applies. The balance funds it, between a floor of 2
   and a ceiling of 20 for each user by default. <!-- vale disable-line STE.IngForms -->
2. **`provision`.** Fountain creates the sandbox and conversation rows, as
   `pending`, then starts a conversation server. That server creates the
   sprite, mounts the skills, and mints a scoped API key that expires. The
   sandbox calls back into Fountain with that key. It assembles the env, and writes
   it into the sprite.

    Then one of two things happens. **`checkpoint_restore`** is a warm start
    from an environment checkpoint, and it skips the rest. Or the cold
    pipeline runs, which is **`packages`, then `network`, then `clone`, then `setup`**.
    The sandbox is then `ready`. A step that fails destroys the sprite, and
    marks the sandbox and the conversation `failed`.
3. **`turn`.** Fountain spawns the runtime, which is claude, codex, gemini or
   opencode, inside the sprite. Its output flows back to the server, which
   redacts it, persists it as log events, and broadcasts it. The LiveView and
   the SSE endpoint both subscribe to the same feed. That endpoint is
   `GET /api/conversations/:id/stream`, and `Last-Event-ID` resumes it.
4. **Idle.** The turn exits and the conversation goes `idle`, with the sandbox
   still warm. A follow-up prompt starts the next turn at once.
5. **`reattach`.** A deploy or the loss of a node can take the server away
   while the sprite survives. The next prompt, or the rehydrator at boot,
   then reattaches. It verifies that the sprite still exists, rewrites its
   env, and picks a turn's session back up where it stopped.

    The runtime's session lives on the sprite's disk. So a reattach to the
    *same* sprite keeps the agent's memory. When the sprite has gone, the
    conversation provisions again from step 2. Fountain's transcript survives,
    and the agent's session does not (#649).
6. **`sandbox`**, which is the lifetime bounds. Each server checks its
   [bounds](guides/operate/sandbox-lifetime.md) each minute, and the two
   bounds do different things.

    To cross the **idle timeout** *suspends*. The server stops, the sprite
    stays and scales itself to zero, and the sandbox parks in `suspended`. The
    next prompt wakes it with everything intact.

    The **max lifetime** is off by default. When an operator sets it, to
    cross it *destroys* an ephemeral sprite and marks the sandbox
    `terminated`, or *parks* a persistent home. The conversation goes back to
    `idle`, and it is resumable at the #649 price. The hourly reaper applies
    the same split to whatever a crashed server left behind.
7. **`terminate`.** An explicit `POST .../terminate` marks the conversation
   `terminated`. That is one of the two terminal states, next to `failed`.
   It destroys an ephemeral sprite that no other conversation holds. A
   shared machine, or a persistent home, stays for the conversations that
   remain on it. `DELETE /api/sandboxes/:id` resets a persistent home. Read
   the [Sandboxes section](api.md#sandboxes) of the API reference.

Here are the two status vocabularies, side by side.

```
conversation:  pending -> running -> idle -> running ...     -> failed | terminated
sandbox:       pending -> starting -> ready <-> suspended    -> terminated | failed
```

A conversation outlives its sandboxes. `idle` with a `suspended` sandbox is
the normal state at rest, and not an error. A max-lifetime reclaim leaves
`idle` with a `terminated` sandbox.

---

## Where to look

The point of this page is that a symptom must predict a component. The action
level, which says what to run and what the output means, is
[Operations](operations.md).

| Symptom | Look at |
|---|---|
| A conversation is stuck or `failed` at startup. | The stage events in its log view name the step that failed. A `packages`, `clone` or `setup` failure is usually the environment's own config. A `provision` that fails outright is sprites.dev, or the sandbox quota. |
| The UI is down, and `GET /health/ready` returns 503. | Postgres. |
| A container restarts in a loop at boot. | Migrations cannot reach Postgres, so the boot fails before it opens a listener. |
| The stream is dead for some viewers and correct for others, on several replicas. | The Erlang cluster, through `CLUSTER_DNS_QUERY`. |
| A signup never completes. | Mail delivery. Read [Email](guides/operate/email.md). |
| `402 insufficient_credits` on a self-hosted instance. | `CREDITS_ENABLED` must be `false`. |
| A sandbox suspends between prompts, and the work resumes on the next one. | That is the design. Read [lifecycle bounds](guides/operate/sandbox-lifetime.md). |
