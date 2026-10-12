# The sandbox contract

Each conversation runs in a sandbox, and each sandbox backend plugs into the
same seam, the `Managoat.Sandbox` behaviour. There is one contract that a
provider must meet, and it is executable. The behaviour, the three hosted
adapters and the conformance suite ship as the `managoat_sandbox` library
(Apache-2.0) in the Fountain repository, under `apps/managoat_sandbox`.

The behaviour's moduledoc specifies the callbacks, the capabilities and the
error taxonomy. `Managoat.Sandbox.ConformanceCase` is the conformance suite
that each adapter must pass. It covers replay-from-start attach, total
`write_stdin`, exactly one terminal frame for each command, `allow: []` as
deny-all, and more.
[ADR 0018](https://github.com/managoat/fountain/blob/main/decisions/0018-sandbox-provider-abstraction.md)
holds the design rationale.

So far, three providers implement it.

| Provider | What it is | Suspend semantics |
|---|---|---|
| [Sprites](sprites.md) | [sprites.dev](https://sprites.dev), the first backend and the instance default. | Parks on its own. The sprite scales to zero and keeps its disk. |
| [E2B](e2b.md) | [e2b.dev](https://e2b.dev) | An explicit `pause`. It snapshots filesystem **and memory**, and restores both on resume. |
| [Self-hosted runner](runners.md) | `fountain runner` on a machine the **user** owns. It dials out to Fountain, and needs no vendor account. | Stops the sandbox's processes. The directory stays. Trusted mode, with no isolation and no egress policy. |

Both hosted providers advertise suspend, network policy and attach. A
runner advertises suspend and attach alone. Only Sprites supports a TTY.

A warm start from a checkpoint exists in the Sprites transport alone, and it
is off by default. A checkpoint id belongs to the sprite that created it, so a
warm start across sprites cannot work (#654).

## How to choose a provider

- Exactly one thing turns a hosted provider on: its credential is there.
  That is `SPRITES_TOKEN` or `E2B_API_KEY`. The runner
  provider has no credential, because each daemon authenticates with the
  user's own API key. So it is on unless you set
  `SANDBOX_RUNNERS_ENABLED=false`.
- `SANDBOX_PROVIDER`, which defaults to `sprites`, sets the instance default
  for a new sandbox. Boot refuses an explicit default whose credential is
  absent.
- An agent can pin a provider with `sandbox_provider`. The provider select
  appears in the agent form on its own, once a second provider is on.
- **A sandbox always stays on the provider that created it.** A parked disk
  lives where Fountain wrote it, so a wake never crosses providers.

You need at least one. With no provider credential, the app boots and each
conversation fails at provision time.

## What the contract guarantees

- **Capabilities are honest.** An adapter advertises only what it can do,
  from `:suspend`, `:network_policy`, `:attach`, `:tty`, `:checkpoint` and
  `:public_url`. The lifecycle then degrades to match. A provider without
  `:suspend` destroys on idle, and does not fake a park. The agent's memory
  lives on the sandbox disk, so a resume with a fresh disk would lose data
  without a sound.
- **The errors are one taxonomy.** Each adapter normalizes the provider's
  errors into the shapes in the behaviour moduledoc, such as `:not_found`,
  `{:unavailable, _}`, `{:denied, _}` and `{:rate_limited, _}`. Retry policy
  is therefore the same on each provider. Fountain also keeps
  `{:error, :not_found}` apart from a transient failure, and that is what
  protects a parked disk from a teardown on one flaky network call.
- **A network policy means what it says.** In a `limited` environment,
  `allow: []` is deny-all on each provider. It is never a no-op.
- **A sandbox URL is real or absent, and never a guess.** A provider that
  gives a sandbox its own HTTP endpoint advertises `:public_url`. Fountain
  stores the URL on the sandbox row, returns it as `sandbox.url` on the
  conversation API, and sets it in the sandbox as **`SANDBOX_URL`**. An agent
  can then answer when you ask where it runs. A provider that exposes a
  hostname for each port instead reports `:unsupported`, and does not return
  an address that would not resolve.

  On Sprites, the endpoint asks for a platform credential by default. So
  Fountain opens it, with `url_settings.auth = "public"`, when it creates the
  sandbox. An agent that serves a page serves it to a person, and that person
  holds no such credential. **So anyone with the URL can reach what an agent
  serves.** Set `config :fountain, :sprites_public_urls, false` to keep the
  default instead. A sandbox then keeps its URL, and only a token holder can
  open it.

## Where to go next

- To configure one provider, read [Sprites](sprites.md) or [E2B](e2b.md).
- To implement the contract for a fourth backend, read
  [Add a provider](adding-a-sandbox-provider.md).
- To build a Sprites-compatible replacement, read the first backend's wire
  protocol in
  [the Sprites transport reference](sprites-contract.md).
- To see what we would ask a sandbox platform to support natively, and what
  each gap costs, read
  [what we need from a platform](platform-requirements.md).
