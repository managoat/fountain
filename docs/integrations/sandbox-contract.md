# The sandbox contract

Each conversation runs in a sandbox, and each sandbox backend plugs into the
same seam, the `Managoat.Sandbox` behaviour. There is one contract that a
provider must meet, and it is executable. The behaviour, the two hosted
adapters Managoat uses (Sprites and E2B) and the conformance suite live in
the server, under
[`apps/fountain/lib/managoat/sandbox`](https://github.com/managoat/managoat/tree/main/apps/fountain/lib/managoat/sandbox)
and `apps/fountain/test/support/managoat/sandbox`. Until 2026-10-15 they were
the `managoat_sandbox` hex package.

The behaviour's moduledoc specifies the callbacks, the capabilities and the
error taxonomy. `Managoat.Sandbox.ConformanceCase` is the conformance suite
that each adapter must pass. It covers replay-from-start attach, total
`write_stdin`, exactly one terminal frame for each command, `allow: []` as
deny-all, and more.
[ADR 0018](https://github.com/managoat/managoat/blob/main/decisions/0018-sandbox-provider-abstraction.md)
holds the design rationale.

So far, two providers implement it.

| Provider | What it is | Suspend semantics |
|---|---|---|
| [Sprites](sprites.md) | [sprites.dev](https://sprites.dev), the first backend and the instance default. | Parks on its own. The sprite scales to zero and keeps its disk. |
| [E2B](e2b.md) | [e2b.dev](https://e2b.dev) | An explicit `pause`. It snapshots filesystem **and memory**, and restores both on resume. |

Both providers advertise suspend, network policy and attach. Only Sprites
supports a TTY.

## How to choose a provider

- Exactly one thing turns a provider on: its credential is there.
  That is `SPRITES_TOKEN` or `E2B_API_KEY`.
- `SANDBOX_PROVIDER`, which defaults to `sprites`, sets the instance default
  for a new sandbox. Boot refuses an explicit default whose credential is
  absent.
- An agent can pin a provider with `sandbox_provider`.
- **A sandbox always stays on the provider that created it.** A parked disk
  lives where Managoat wrote it, so a wake never crosses providers.

You need at least one. With no provider credential, the app boots and each
conversation fails at provision time.

## What the contract guarantees

- **Capabilities are honest.** An adapter advertises only what it can do,
  from `:suspend`, `:network_policy`, `:attach`, `:tty` and
  `:public_url`. The lifecycle then degrades to match. A provider without
  `:suspend` destroys on idle, and does not fake a park. The agent's memory
  lives on the sandbox disk, so a resume with a fresh disk would lose data
  without a sound.
- **The errors are one taxonomy.** Each adapter normalizes the provider's
  errors into the shapes in the behaviour moduledoc, such as `:not_found`,
  `{:unavailable, _}`, `{:denied, _}` and `{:rate_limited, _}`. Retry policy
  is therefore the same on each provider. Managoat also keeps
  `{:error, :not_found}` apart from a transient failure, and that is what
  protects a parked disk from a teardown on one flaky network call.
- **A network policy means what it says.** In a `limited` environment,
  `allow: []` is deny-all on each provider. It is never a no-op.
- **A sandbox URL is real or absent, and never a guess.** A provider that
  gives a sandbox its own HTTP endpoint advertises `:public_url`. Managoat
  stores the URL on the sandbox row, returns it as `sandbox.url` on the
  conversation API, and sets it in the sandbox as **`SANDBOX_URL`**. An agent
  can then answer when you ask where it runs. A provider that exposes a
  hostname for each port instead reports `:unsupported`, and does not return
  an address that would not resolve.

  On Sprites, the endpoint asks for a platform credential by default. So
  Managoat opens it, with `url_settings.auth = "public"`, when it creates the
  sandbox. An agent that serves a page serves it to a person, and that person
  holds no such credential. **So anyone with the URL can reach what an agent
  serves.** Set `config :fountain, :sprites_public_urls, false` to keep the
  default instead. A sandbox then keeps its URL, and only a token holder can
  open it.

## Reads and provider sleep

The four sandbox read operations (a directory listing, one file, `git status`
and `git diff`) run a fixed script in the sandbox through the seam's `exec`.
Managoat coordinates them with its own lifecycle. It does not control the
provider's.

- **Managoat's park and destroy.** A read never resumes a sandbox Managoat
  parked: a `suspended` sandbox answers `409 sandbox_not_ready` and the
  provider is not called. A `ready` row with an unfinished resume, park or
  destroy answers `503 sandbox_unavailable` with a `Retry-After`. A park or destroy
  waits for a read that was admitted before it.
- **The provider's own sleep.** A `ready` sandbox can be asleep at the
  provider. A read wakes it, and the provider bills for the time it then runs.

| Provider | When a `ready` sandbox is asleep | What a read does | Run only if awake? |
|---|---|---|---|
| Sprites | Often. A sprite scales to zero on its own when nothing runs in it, and Managoat's park does not call Sprites. | Wakes the sprite, which sleeps again on its own. | Not offered. |
| E2B | When its timeout lapsed without a heartbeat. Managoat creates E2B sandboxes to pause, not die, on a lapsed timeout. | Resumes the sandbox with a 30-minute timeout, then runs the read. | Not offered. Running a command resumes a paused sandbox. |

A read is not turn activity, so it does not delay the idle park
(`SANDBOX_IDLE_TIMEOUT_MINUTES`). A client that polls the files API can keep a
sandbox awake until that park, and the reads then answer `409`. With the idle
timeout set to `0`, nothing ends that. `GET /api/sandboxes/{id}` reads
Managoat's database and never wakes anything; a `status` of `ready` there does
not mean the machine is awake at the provider.

Managoat does not ask the provider whether a sandbox is awake before a read.
That would be a second call, and the provider could put the sandbox to sleep
between the two. [ADR 0039](https://github.com/managoat/managoat/blob/main/decisions/0039-sandbox-files-over-the-api.md)
records this decision.

## Where to go next

- To configure one provider, read [Sprites](sprites.md) or [E2B](e2b.md).
- To implement the contract for a third backend, read
  [Add a provider](adding-a-sandbox-provider.md).
- To build a Sprites-compatible replacement, read the first backend's wire
  protocol in
  [the Sprites transport reference](sprites-contract.md).
- To see what we would ask a sandbox platform to support natively, and what
  each gap costs, read
  [what we need from a platform](platform-requirements.md).
