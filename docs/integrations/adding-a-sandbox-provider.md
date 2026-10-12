# Add a sandbox provider

Fountain runs a conversation on a pluggable sandbox backend, behind the
`Managoat.Sandbox` behaviour. Today those are Sprites, E2B and the
self-hosted runner. This page is the practical checklist for another one.
The behaviour and the hosted adapters are the `managoat_sandbox`
library, published on [Hex](https://hex.pm/packages/managoat_sandbox) with
source in [managoat/managoat_sandbox](https://github.com/managoat/managoat_sandbox).
Fountain pins it in `apps/fountain/mix.exs`. The runner adapter is a separate
[managoat_runner library](https://github.com/managoat/managoat_runner) that
implements the same behaviour.

Three places hold the contract itself.
[ADR 0018](https://github.com/managoat/fountain/blob/main/decisions/0018-sandbox-provider-abstraction.md)
holds the *why* behind the shape of the seam. The `Managoat.Sandbox` moduledoc
is the contract. `Managoat.Sandbox.ConformanceCase` is the executable form of
it. When one of those disagrees with this page, it wins.

For the same territory from the platform's side of the table, read
[what we need from a platform](platform-requirements.md). It covers what we
would ask a vendor to support natively, and what each gap costs us.

## Before you write any code, answer six questions

Each hard defect in the E2B adapter, and in the Daytona adapter that
Fountain ran until 2026-10, came from one of these.
Answer them against the provider's real API. Run the calls, and do not trust
the docs.

Both adapters shipped with research that somebody verified against the
official specs. That research was *still* wrong on five counts once we
measured it live.

1. **Identity.** Can you create a sandbox with a name you choose, then fetch
   it by that name? Daytona can. E2B cannot, so the adapter emulates a name
   with metadata filters and adopt-on-list. Fountain always mints the name,
   as `fountain-<prefix>-<hex>`. Your adapter must make create idempotent, so
   that a create against a name that exists adopts it. Your `get` must tell
   `{:error, :not_found}` apart from a transient failure, because that is
   what protects a parked disk from a teardown on one flaky network call.
2. **Suspend.** Is there a park state that keeps the *disk* at a lower cost,
   and a resume that returns the same disk? The agent's memory lives on the
   sandbox filesystem, so a resume with a fresh disk loses data. It is not a
   degradation. If the provider cannot do this, do not fake it. Omit the
   `:suspend` capability, and `Lifecycle.idle_action/1` destroys on idle
   instead. Honest amnesia beats amnesia that says nothing.
3. **Streams.** How do you get the stdout and stderr of a long process, live?
   And, above all, can a client that *reconnects* replay the output from byte
   zero? The attach contract demands replay from the start. E2B's daemon
   cannot replay, so the adapter uses a `tee` shim that journals, and a tail
   replayer. Daytona's follow websocket turned out to be unusable live, so
   the adapter polls the HTTP journal. Expect to build something here.
   Measure the vendor's stream endpoint with raw bytes before you trust it.
4. **stdin.** Can you write to a live process's stdin again and again, and
   send a real EOF? An ACP turn holds stdin open for the whole turn and
   writes NDJSON into it. Daytona's input endpoint sent EOF to the pipe after
   each write, so the adapter routes stdin through a file that `tail` feeds.
   Also, `write_stdin` must be *total*. A write to a command that exited
   returns `{:error, :command_exited}`, and never crashes the caller.
5. **Exit codes.** Does the provider report the exit code of a spawned
   command reliably? Daytona does not, so the spawn shim writes an exit
   sentinel file. Never invent an exit 0. A stream that closes with no
   verdict is exit 0 only when the contract's close-without-exit rule
   applies.
6. **Egress.** Is there a deny-by-default network mode with a domain
   allowlist you can update at runtime? If so, advertise `:network_policy`,
   and remember that `allow: []` means *deny all*, and never a no-op. If the
   tier gates it, as Daytona's did, document the failure. A `limited`
   network environment then fails to provision on that provider.

One note on a provider we rejected. The original campaign passed over Modal,
because its control plane is gRPC alone, and everything else here is plain
HTTP with Req. Revisit that only if it changed, or if you are ready to take a
gRPC dependency.

## The code checklist

A provider change crosses two repositories. Open the adapter and conformance
PR in the library, publish its Hex release, then bump Fountain's dependency
pin and register the provider here. Follow the
[component library contribution recipes](https://github.com/managoat/fountain/blob/main/CONTRIBUTING.md#graduating-a-library)
for the library gates, release and consumer PR. A local path override can test
the two changes together before release; the committed pin must name a
published version.

Registration centers on `apps/fountain/lib/fountain/sandbox_providers.ex`. The changeset
validations and the schema-enum guardrail derive from `known_providers/0`.
Three lists are still literals, and the guardrail is what catches the drift.
Those are the `sandbox_provider` enums in `fountain_web/schemas.ex`, on Agent,
AgentCreate and AgentUpdate, and the `SANDBOX_PROVIDER` boot check in
`config/runtime.exs`. Budget for those edits.

1. **Adapter modules**, in the `managoat/managoat_sandbox` repository, under
   `lib/managoat/sandbox/<provider>/`. You need the
   adapter, with `@behaviour Managoat.Sandbox`, an API client, and whatever stream or
   command-server processes the provider needs. Keep the provider's secrets
   out of an inspection of `Handle.private`. The struct already excludes
   `private` from Inspect, so do not defeat that. Normalize each error into
   the taxonomy in the behaviour moduledoc, in an `errors.ex`. That is
   `:not_found`, `{:unavailable,_}`, `{:denied,_}`, `{:rate_limited,_}` and
   the rest, because `Managoat.Sandbox.Retry` keys retryability off those
   shapes.
2. **Register it.** Add the module to the adapter map in `config/config.exs`
   (`config :managoat_sandbox, adapters: ...`). Then add the atom to
   `Fountain.SandboxProviders.known_providers/0` and a `credential_present?/1`
   clause in the same module. "On" is exactly "you registered the adapter AND
   the credential is there". There is no other switch. The provider select in
   the agent form appears on its own, once a second provider is on.
3. **Config.** Add the env vars to `config/runtime.exs`, written to
   `config :managoat_sandbox, Managoat.Sandbox.<Provider>, ...`. The adapter
   reads them through `Managoat.Sandbox.Config`. You need
   `<PROVIDER>_API_KEY`, and a base URL and image knobs, where blank equals
   unset. Then add rows to `docs/configuration.md`, `.env.example`,
   `.env.compose.example` and `docker-compose.yml`.
4. **Conformance.** Add a test with
   `use Managoat.Sandbox.ConformanceCase, adapter: ...` and Req.Test stubs for
   the provider API. Where a sandbox name has to carry a route, mint the
   names with `name: {Mod, :fun, args}`, the way the runner adapter does.
   This is the gate that catches contract drift. It covers exec-never-raises,
   `write_stdin` totality, replay from the start, one terminal frame, and
   `allow: []` as more than a no-op.
5. **Image.** Write a Dockerfile under `images/<provider>/`. It bakes the
   `sprite` user, with passwordless sudo and `/home/sprite`. It bakes node,
   npm, bun and git, and the agent CLIs. It also bakes **an npm global prefix
   that `sprite` can write to**, with
   `npm config set prefix /home/sprite/.npm-global`. Without that, the
   `npm install -g --silent` at provision fails as a silent exit 243. If
   commands run as a user the provider selects, make sure that user is
   `sprite`. Compare `E2B_USER`.
6. **Docs.** Add a `docs/integrations/<provider>.md` page and a `docs/nav.yml`
   entry, modelled on `e2b.md`. The nav entry is not optional.
   Fountain serves only the pages the nav names, so a page you leave out of it
   reaches no reader. The test suite fails until you add it.

## Two traps that both adapters hit

- **Spawn must not return before the provider acks the process.** The ACP
  peer writes `initialize` within milliseconds of the return from spawn. An
  adapter that returns from `spawn` while the daemon-side registration is
  still in flight fails prod turns, and the failure looks like "process
  exited". E2B lost that race in about 300ms, and PR #693 fixed it. Block on
  the daemon's start acknowledgment.
- **A local success proves less than you think.** The E2B race passed each
  local run and both full local cycles, on latency luck. Daytona's websocket
  looked fine in unit tests. The verification ladder below exists because
  each rung caught something the rung before it could not.

## The verification ladder

Run these in order. Each rung has caught a real defect that the rung before
it passed.

1. `mix test`, with the conformance suite green against your Req.Test stubs.
2. **A live adapter smoke** against a real account. Exercise each behaviour
   callback. That includes suspend and resume with a file that survives the
   round trip, an attach replay, and an egress deny and allow.
3. **A full conversation cycle** locally, on the custom image.
   `start_conversation`, a real model turn, an idle park, a status check on
   the provider side, a wake, a second turn, a terminate. The sandbox is then
   gone on the provider side.
4. **A prod smoke** after the merge and the deploy. Pin an agent to the
   provider with `sandbox_provider` on `POST /api/agents`. Run one
   conversation through the public API. Poll the **turn status**, and not
   `turn_count`, because a turn that failed still counts. Read the answer
   from `/events`, terminate, then confirm that the provider account is
   clean.

Two things remain after that. The provider's key goes to the Infisical prod
project, which syncs it into `fountain-secrets` and reloads the deployment on
its own. And the image needs a rebuild, because the agent CLIs in it go stale
in weeks.

The `Sandbox images` workflow owns the rebuild. Give the new provider a
`scripts/sandbox-image/build-<provider>.sh` that rebuilds the image and then
smokes it. Add a matrix entry, so that `docker build` proves the Dockerfile on
the runner first. Then add a job that runs the script with the account key as
a repository secret. That key must belong to the account prod uses. An image
that another account builds is not visible to prod.

Every one of those scripts ships `scripts/sandbox-image/smoke.sh` into the new
sandbox and reads its verdict. Keep the checks in that one file. It is the
statement of what an image must give the provision pipeline, and it holds each
provider to the same contract.
