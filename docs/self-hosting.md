# Self-host Managoat

Managoat is an open-source, self-hosted application. Nobody sells it as a
hosted service. This section is about an instance of your own that stays up.
For a development checkout on your own machine, read
[SETUP.md](https://github.com/managoat/managoat/blob/main/SETUP.md) in the
repo instead.

Start with [Deploy an instance](guides/operate/deploy.md).

This manual describes the `main` branch, not the release that you deploy.
Read [Which version this is](index.md#which-version-this-is) before you rely
on a page for an older version.

## What you must have

| | |
|---|---|
| **Postgres 16+** | The compose file runs one for you. |
| **A sandbox provider** | [sprites.dev](https://sprites.dev) is the default. [E2B](integrations/e2b.md) is the other host. The app boots without a provider, but then each conversation fails. The provider account behind the token is this instance's alone: do not share it with another app or instance ([why](integrations/sprites.md#one-organization-per-instance)). |

A sandbox runs on one of two hosted backends. Somebody else runs both as a
service, so a Managoat instance that uses them is not self-contained.

| Provider | Turned on by | When idle | Notes |
|---|---|---|---|
| **Sprites** (default) | `SPRITES_TOKEN` | Parks, and scales to zero on its own. | The reference backend. |
| **E2B** | `E2B_API_KEY` | Parks on an explicit pause, with a snapshot of filesystem and memory. | Needs a template built from `images/e2b/`. Read [E2B](integrations/e2b.md). |

`SANDBOX_PROVIDER` chooses the default for a new sandbox. An agent can pin a
provider. A sandbox that already exists always stays where Managoat made it.
The contract a new backend must satisfy is `Managoat.Sandbox` and its
conformance suite; [the sandbox contract](integrations/sandbox-contract.md)
writes it down.

[Architecture](architecture.md) says what each piece of the system does, and
what breaks when a dependency is down.

## Who owns what

An instance splits into four parts. You run two of them, and two run on
accounts of yours at another company.

| Part | Where it runs | Who answers for it |
|---|---|---|
| **Control plane and database** | Your deployment and your Postgres. That covers the API, the console, conversations and their transcripts, the audit trail and API keys. | You. |
| **`MASTER_SECRETS_KEY`** | Wherever you keep it. It is never stored in the database. It wraps the key that encrypts each account's secrets. | You. Back it up with the database. Lose it, and no database restore brings the secrets back. Read [Back up and restore](guides/operate/back-up-and-restore.md). |
| **Sandbox compute** | Sprites or E2B, under a token your instance holds. | The provider, which bills you for the machines. Managoat suspends a sandbox after `SANDBOX_IDLE_TIMEOUT_MINUTES` without a turn, 60 by default. Read [Sandbox lifetime and cost](guides/operate/sandbox-lifetime.md). |
| **Inference** | Each user's model provider. | Each user brings their own model credential, and their provider bills them directly. Managoat adds nothing to the token bill. |

## What it costs you to run

The software costs nothing. There is no licence key and no seat count. Running
it is not free, and these are the four costs.

- **A sandbox provider account.** Choose Sprites or E2B before the first
  conversation, because without one every conversation fails. Its invoice is
  the infrastructure bill that grows with use. Read
  [What sandboxes cost](guides/operate/sandbox-lifetime.md#what-sandboxes-cost).
- **Email, before you invite anyone.** Verification and password resets go
  through an SMTP server. With no `SMTP_HOST`, the default, mail is off and
  an account verifies itself, so the first one can register. That is right
  for one operator, and wrong once you invite other people, who cannot reset
  a forgotten password. Read [Configure email](guides/operate/deploy.md#configure-email).
- **A backup of the master key, before you have data.** A database backup
  without the key that decrypts it holds no usable secrets.
- **Every upgrade.** Change the pinned image tag, pull it, and read the
  release's upgrade notes. Migrations run at boot. Nobody else upgrades your
  instance, so nobody upgrades it without asking you either. Read
  [Take a new version](guides/operate/upgrade.md#take-a-new-version).

## What a host must give you

Managoat is one long-lived Erlang process with a database beside it. Three
properties decide whether a host suits it.

| | |
|---|---|
| **One instance, and only one** | Managoat runs as one node. A second replica knows nothing of the first, and two schedulers then race over the same sandboxes. A deploy must stop the old instance before it starts the new one. |
| **A process that never parks** | The sandbox reaper and the retention pruner run inside the app process. A host that stops an idle instance stops both, and nothing reports the loss. |
| **Long-lived connections** | The event streams are Server-Sent Events, and one turn runs for minutes. A host with a short request limit cuts them. |

Some popular hosts fail one of these, and they fail it quietly.

- **Cloud Run, AWS App Runner and Lambda** scale to zero between requests and
  add instances under load. An instance looks healthy and stops its own
  background work.
- **Vercel, Netlify and Cloudflare Workers** run a function per request.
  Managoat needs a process that outlives the request.
- **Render.** Managoat does not run there with the credential broker
  (ADR 0019) turned on.

Any host that runs one container, keeps it awake and offers a Postgres works.

## The guides

| Guide | What it covers |
|---|---|
| [Deploy an instance](guides/operate/deploy.md) | Docker Compose from first boot to a first conversation, then TLS and a public URL, an external database, and email. |
| [Deploy on another host](guides/operate/hosts.md) | Kubernetes, Fly.io and Coolify. |
| [Back up and restore](guides/operate/back-up-and-restore.md) | The dump, the key that decrypts it, and the restore drill. |
| [Upgrade an instance](guides/operate/upgrade.md) | Image tags, taking a new version, and what to do when one goes wrong. |
| [Sandbox lifetime and cost](guides/operate/sandbox-lifetime.md) | The two bounds that reclaim a sandbox, and how to read what sandboxes cost. |
| [Observability](guides/operate/observability.md) | Metrics, alerts, dashboards, logs, errors and the health endpoints. |
| [Run a release task](guides/operate/run-a-release-task.md) | The pattern for an operator action that touches data, and the tasks. |

When something is wrong, start from the symptom in
[Troubleshoot a problem](troubleshooting/index.md).

## Licence

| Part | Licence |
|---|---|
| The server (`apps/fountain`) | [Apache-2.0](https://github.com/managoat/managoat/blob/main/LICENSE) |
| `cli/` and `sdk/typescript` | [Apache-2.0](https://github.com/managoat/managoat/blob/main/cli/LICENSE) |

You can run your own instance, run it commercially, change it, and keep your
changes private. Neither a connection to Managoat nor a changed server that
you host puts a copyleft obligation on you. Keep the licence and the `NOTICE`
file when you redistribute any of it.

Earlier releases used other licences, and each grant stays with the releases
made under it: v0.12.0 and earlier were MIT, and v0.13.0 through v0.21.0 were
AGPL-3.0-or-later. The
[NOTICE](https://github.com/managoat/managoat/blob/main/NOTICE) file records
the history and holds the third-party attribution.

## Where things live

**Managoat** is the project: the server, the CLI, the TypeScript SDK, this
manual and the GitHub organization, and its public names say so: the
`managoat` CLI, the `MANAGOAT_*` variables, the `@managoat/sdk` package, the
`ghcr.io/managoat/managoat` image and the `managoat/managoat` repository. The
project was formerly Fountain, and the old names (`fountain`, `FOUNTAIN_*`,
`@managoat/sdk`, `ghcr.io/managoat/managoat`, `managoat/fountain`)
keep working for a while, as aliases and redirects. A later release drops
them. The code's internal names, such as the `Fountain.*` Elixir modules and the
database, keep the old name. `managoat.com` is the
maintainer's own instance. It deploys the image and the `deploy/` manifests
that every merge to `main` publishes, with the egress broker on. Its
cluster-specific settings are a private overlay of patches in another
repository, and no code is. The
[configuration reference](configuration.md) lists every switch, so an
instance of your own can match it or not.

| You want | Go to |
|---|---|
| The code, issues and pull requests | [github.com/managoat/managoat](https://github.com/managoat/managoat) |
| The manual | This site, at [managoat.com/docs](https://managoat.com/docs). It is built from `docs/` in the repo on `main`. The `/docs` of an instance redirects here, and `DOCS_URL` changes where. |
| The reasons behind the design | `decisions/` in the repo. The ADRs are not on this site. |
| The CLI | `brew install managoat/tap/managoat`, or the [CLI guide](cli.md). |
| The TypeScript SDK | `@managoat/sdk` on npm, or the [TypeScript reference](sdk.md). |
| The Python, Elixir or Swift SDK | Retired. `fountain-agent-sdk` on PyPI, `fountain_sdk` on Hex and the `sdk-swift-v*` tags stay published but are no longer maintained; use the TypeScript SDK or the [HTTP API](api.md). |
| To contribute | [CONTRIBUTING.md](https://github.com/managoat/managoat/blob/main/CONTRIBUTING.md) and [CLAUDE.md](https://github.com/managoat/managoat/blob/main/CLAUDE.md); the [manual contribution guide](https://github.com/managoat/managoat/blob/main/contributing/docs.md) covers these pages. |

This manual is the project's documentation, and the repo README is its front
page. The pages at `managoat.com` itself, the homepage and the list of apps
built on the API, are in `site/` in the repo.
