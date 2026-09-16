# Deploy an instance

This guide takes a Fountain instance from first boot to its first successful
conversation with Docker Compose. You verify readiness, create the first admin
account, close registration, and exercise the database, encryption, inference
and sandbox provider end to end.

For a development environment on your own machine, read
[Setup](../../setup.md). That is a different thing. This guide is for an
instance that stays up.

## Before you start

You must have Docker Engine with Compose v2, and `openssl` for the two key
lines below. Fountain requires Postgres 16 or newer. The compose file runs one
for you, or you can point Fountain at a Postgres you operate.

Your machine must also reach `ghcr.io`, the registry that holds the published
image. Does your network block it? Then comment the `image:` line in
`docker-compose.yml`, uncomment the `build: .` line under it, and compose
builds the image from this checkout.

You must also have a sandbox provider token. Read
[Self-host Fountain](../../self-hosting.md) for what each provider needs, and
for where a token comes from.

## Bring it up

```bash
git clone https://github.com/managoat/fountain
cd fountain

cp .env.compose.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env
# add your SPRITES_TOKEN to .env

docker compose up -d
```

Do you reach this instance by a host other than `localhost`? Then set
`PUBLIC_URL` in `.env` as well. It defaults to `http://localhost:4000`, it
builds the links in verification emails, and every sandbox reads it as
`FOUNTAIN_BASE_URL`. [Put it on the internet](put-it-on-the-internet.md)
covers the rest of a public deployment.

Back `MASTER_SECRETS_KEY` up now, before you have data. It is not in the
database, so a database backup alone does not protect you. Read
[Back up and restore](back-up-and-restore.md).

These guides explain each variable that shapes a deployment as it comes up.
The [configuration reference](../../configuration.md) holds the complete list,
and it includes the deploy-level variables that the compose file never
mentions.

## Verify the instance is ready

The app applies database migrations before it opens a listener, so a cold
start takes up to a minute. Wait for the app container to report `healthy`,
then probe it.

```bash
docker compose ps
# wait for the app to report healthy, then:
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

Expect refused connections during first boot until migrations finish. If the
app still refuses connections after a minute, inspect
`docker compose logs -f app`.

## Register the first account

Open <http://localhost:4000> and create your account.

The compose defaults are `EMAIL_DELIVERY=none` and `FIRST_USER_ADMIN=true`.
Your account then self-verifies at registration, and Fountain promotes it to
admin because it is the first. The admin audit trail records the grant, like
any other role change (ADR 0011).

Register **before** you expose the instance to a network you do not trust.
While no admin exists, the first verified account takes the role.

For the manual path, set `FIRST_USER_ADMIN=false` and use a release task. Read [Run a release task](run-a-release-task.md).

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.promote_admin("you@example.com")'
```

## Close registration

```bash
echo "REGISTRATION_ENABLED=false" >> .env
docker compose up -d
```

Registration is open by default. Disable it immediately after you create the
first admin and before you expose the instance to an untrusted network.

## Point the apps at it

Fountain's own UI is a console. It covers the account, its keys, and the
agents, environments and vaults that a conversation runs on. To watch a
conversation turn by turn, and to message an agent as a teammate, you use
separate single-page apps that talk to your `/api`.

| | |
|---|---|
| [Conversations](https://fountain-conversations.demo.managoat.com/) | Start a run, watch it, steer it, read the raw log. |
| [Team](https://fountain-team.demo.managoat.com/) | Your agents as teammates, one thread for each. |

They are static builds with no server of their own. You type your Fountain's
URL in, so the hosted copies above work against your deployment as soon as it
admits the origin.

```bash
echo "API_CORS_ORIGINS=https://fountain-conversations.demo.managoat.com" >> .env
```

To click "Sign in with Fountain" instead of a paste of an API key, register
them in `OAUTH_CLIENTS`. Read the
[configuration reference](../../configuration.md).

The console links to whatever `CONVERSATIONS_APP_URL` and `TEAM_APP_URL` say.
Point those at your own build of either repo and it works the same way. Set
them to `""` to tell the console that this deployment has neither, and the
console stops the offer.

## Prove the whole path

Readiness checks Fountain's connection to Postgres. It does not check
encryption, inference credentials or the sandbox provider. In the console, add
a model credential under Settings, then Inference credentials. Open
Conversations and start a run. A first turn confirms that Fountain can read
Postgres, decrypt the credential, reach the model provider and start a sandbox
through the selected provider.

## Start over

```bash
docker compose down -v
```

The `-v` flag deletes the database volume, and every account and conversation
in it. Keep the same `MASTER_SECRETS_KEY` when you keep the volume. A new key
cannot unwrap what the old key wrapped. Every stored environment and vault
value then becomes unreadable.

## If it did not work

Does the app serve while a sandbox fails to start? The sandbox provider is the
usual cause. Read [Sandbox errors](../../troubleshooting/sandbox-errors.md).

If the container never opens a listener, migrations cannot reach the
database. Read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md).

## Related

- [Put it on the internet](put-it-on-the-internet.md), the next step.
- [Back up and restore](back-up-and-restore.md).
- [Configuration reference](../../configuration.md).
- [Architecture](../../architecture.md), for what runs, and what breaks when a
  dependency is down.

## Verify the deployed instance

The external suite checks public HTTP and SSE through your ingress. Use Node
24 or newer from a pinned Fountain checkout. It needs no application database
access. Provision two dedicated, verified test accounts and full-scope API
keys through the console. Configure inference credentials on the primary
account for execution checks. Keep both accounts separate from customer data;
registration can remain closed. Limit provider spending on that account with
the provider's own budget controls.

Load the two keys into `FOUNTAIN_SUITE_KEY` and `FOUNTAIN_SUITE_OTHER_KEY`
through your secret store, then point the suite at the instance:

```bash
scripts/verify-deployment.sh http://localhost:4000 basic
scripts/verify-deployment.sh https://fountain.example.com
```

The first checks a local Compose instance's API surface. The second runs the
default `streaming` profile against a remote one: a real conversation with two
tool-using turns, live output, reconnect, replay and history. It prints the
failing checks, how many fixtures are left behind and where the evidence is.
Plaintext HTTP is accepted only for a loopback target, and a URL carrying
credentials, a query or a fragment is refused before anything is written.

On macOS a key you have not exported is read from the keychain, under an
account naming the exact target it belongs to:

```bash
security add-generic-password -U -s fountain-deployed-suite \
  -a 'https://fountain.example.com|FOUNTAIN_SUITE_KEY' -w
```

A stored key is only ever offered to that origin, so one kept for a production
instance is never sent to a local one, and pointing the command at an unrelated
host finds nothing rather than disclosing a key to it.

Select coverage with the second argument: `probe` for identity, capability and
health checks, `basic` for the API surface without a sandbox, `execution` for
two turns without streaming conformance, `canary` for both, or `streaming` for
everything. Missing required credentials or capabilities fail the run; they
never become passing skips. The integration profiles — `secrets`, `mcp`,
`webhooks` and `schedules` — need configuration these flags do not supply, and
run from a target file through `deployed/cli.mjs`.

Change what the run declares with flags, which
`node deployed/verify.mjs --help` lists in full:

```bash
node deployed/verify.mjs https://fountain.example.com --profile execution \
  --runtime codex --model openai/gpt-5.5 --sandbox e2b
```

For a run that needs a field those flags do not cover, write a target file and
use the underlying CLI. The same two keys apply:

```json
{
  "base_url": "http://localhost:4000",
  "credentials": {
    "primary": "FOUNTAIN_SUITE_KEY",
    "secondary": "FOUNTAIN_SUITE_OTHER_KEY"
  },
  "profiles": ["basic"]
}
```

```bash
node deployed/cli.mjs run --config /tmp/fountain-target.json --out /tmp/fountain-check-001
```

For a real conversation through that path, select `streaming` and add explicit
execution settings:

```json
{
  "execution": {
    "runtime": "claude",
    "model": "anthropic/claude-haiku-4-5",
    "sandbox_provider": "sprites",
    "provision_ms": 120000,
    "turn_ms": 90000,
    "max_turns": 2
  },
  "limits": {
    "request_ms": 30000,
    "run_ms": 420000,
    "cleanup_ms": 90000,
    "resources": 12
  }
}
```

Merge those fields into the target file. This checks a nonce artifact, two
real tool-using turns, tenant isolation, live output, reconnect, replay and
history agreement, then terminates and deletes its fixtures.

### Run in CI

The `Deployed verification` workflow accepts only `staging` and `production`
and runs code from `main`. Create the matching GitHub environment,
`deployed-staging` or `deployed-production`, and restrict its deployment branch
to `main`. Configure these environment settings:

| Setting | Purpose |
|---|---|
| Variable `SUITE_ENABLED=true` | Explicitly enable this target. |
| Variable `SUITE_TARGET_JSON` | Target JSON with approved HTTPS URL, required capabilities and execution settings. |
| Secret `FOUNTAIN_SUITE_KEY` | Primary dedicated test account API key. |
| Secret `FOUNTAIN_SUITE_OTHER_KEY` | Different verified account's API key. |
| Secret `SUITE_KUBECONFIG` | Optional read-only Kubernetes access for rollout mode. |
| Secret `SUITE_MONITOR_URL` | Sentry Crons check-in URL for the scheduled canary. |

The workflow fixes credential variable names and bounds each run to seven
minutes plus 90 seconds for cleanup. It creates at most 12 resources and
attempts at most two inference prompts. These limits do not cap the monetary
cost of a model turn. Profiles run sequentially. All dispatches and schedules
share one concurrency group per target, and an active run is never cancelled
by a newer one. GitHub can replace a pending run; use a separate workflow run
ID when recording which rollout received verification.

```bash
gh workflow run deployed.yml --ref main \
  -f target=staging -f profile=streaming -f mode=public
```

Public mode needs no cluster credentials and reports deployment identity as
unverified. Every initialized suite run retains `result.json`, `junit.xml`,
redacted traces and `cleanup.json` as a 30-day Actions artifact. Setup failures
before runner initialization remain visible in the workflow log. Credential
files are outside the uploaded directory and are removed at job completion.
Copy unresolved cleanup manifests to durable incident storage before expiry.

### Invoke after rollout completion

The deployment owner invokes the same workflow **after** migrations and the
serving deployment have finished rolling out. Neither image publication nor
manifest publication invokes this workflow. In a Flux installation, wait for
the relevant Kustomization's intended source revision and Deployment rollout,
then dispatch verification. Do not treat Flux receiving a webhook as completion.

For Kubernetes, add an adapter to the environment-owned `SUITE_TARGET_JSON`:

```json
{
  "deployment": {
    "adapter": "kubernetes",
    "context": "staging",
    "namespace": "fountain",
    "deployment": "fountain",
    "service": "fountain",
    "container": "fountain"
  }
}
```

The deployment owner must verify that the configured public URL routes only
to this Service, including any ingress, CDN, tunnel or regional routing. This
binding is an explicit trust input; the adapter does not discover it from a
successful HTTP response. Give its Kubernetes identity only `get` and `list`
on Deployments, ReplicaSets, Pods, Services and EndpointSlices in this namespace.
The CI runner must reach the API server. Public-only checks remain usable
when it cannot.

Obtain the intended image digest from the release's registry manifest or build
provenance, independently of the running pods. Match the kind of identity
reported by your container runtime: some report the multi-architecture image
index digest; others report a platform manifest digest. The registry supplies
both. This adapter requires one expected digest across the serving deployment;
a fleet reporting different platform digests needs a future platform-aware
adapter. Keep the registry's commit-to-digest provenance with the rollout
record. The suite verifies the digest and does not independently claim a source
commit from a mutable image tag.

```bash
kubectl --context staging -n fountain rollout status deployment/fountain --timeout=5m
gh workflow run deployed.yml --ref main \
  -f target=staging -f profile=streaming -f mode=rollout \
  -f expected_digest="$EXPECTED_IMAGE_DIGEST"
```

The adapter checks observed generation, all desired replicas, Pod ownership,
container readiness and the intended digest. It reads every EndpointSlice
for the Service and rejects missing, extra or terminating backends. It repeats
the observation after public checks and cleanup; changed membership,
generation, image or restart counts invalidate attribution. Reports retain
both observations without raw cluster objects. These observations establish
identity at the boundaries; they are not a continuous audit of all routing
changes during the run.

For a local invocation of rollout mode, include `expected_digest` in the
`deployment` object and run the normal CLI with your read-only kubeconfig.
For other deployment types, run public mode until an external identity adapter
covers all their serving replicas. Never relabel that result as revision-verified.

### Schedule and failure ownership

After a manual `canary` profile passes against the intended production target,
configure its Sentry monitor and set the **repository** variable
`DEPLOYED_CANARY_ENABLED=true`. The schedule runs basic API checks and two
real execution turns at 00:23, 06:23, 12:23 and 18:23 UTC. It is disabled until
that explicit configuration exists; this repository change alone does not
activate production runs.

Reuse the [Sentry Crons channel](../../integrations/sentry.md#crons-an-alert-when-a-scheduled-job-stops)
for start, success and error check-ins, correlated by workflow run and attempt.
Configure the monitor on the same
six-hour schedule, a 30-minute check-in margin, a 12-minute maximum duration,
an issue threshold of two consecutive failures and recovery after one success.
Route its issues to the deployment's existing operational owner. Sentry keeps
the consecutive-failure history and catches missed schedules; no repository
cache is used as an incident ledger. A monitor delivery failure is visible in
Actions, and a missing monitor URL fails a scheduled run before inference.
Confirm the monitor's incident and recovery behavior before enabling the schedule.

Use the existing [stage and provider alert policy](observability.md#which-alerts-you-get)
to investigate canary failures alongside request IDs, provider health and
runtime logs. A canary is additional external evidence for the same incident,
not a separate rollback trigger. Assign setup, ingress, revision and cleanup
failures to the deployment owner; assign runtime/provider failures to that
owner for provider triage; assign reproducible contract failures to the API
maintainer. Record the actual named owners in the environment's operations
record before activation.

Start with visible verification. Before making this a promotion gate, collect
at least 28 consecutive scheduled successes over seven days, zero unresolved
cleanup entries, tested failure/recovery notification delivery and a named
responding owner. Review durations and provider spending, and separate observed
provider outages from suite defects. Blocking promotion is a separate change;
this workflow does not modify a release, deployment or rollback policy.

On failure, inspect the failing phase and `revision` evidence in `result.json`.
Check cleanup even when public assertions passed. Retry cleanup with the same
URL and account:

```bash
node deployed/cli.mjs cleanup --config /tmp/fountain-target.json \
  --manifest /tmp/fountain-check-001/cleanup.json --out /tmp/fountain-cleanup-001
```

Keep the manifest until every resource is cleaned. Never delete fixtures by a
broad name prefix. An interrupted creation may commit after a timeout; an
unresolved intent remains an incident until reconciled. Preserve failed-run
evidence when repeating verification, and use a new output directory.
