ExUnit.start()

# ─── The `-core` distribution's own assertions (#1574) ───────────────────────
#
# A handful of tests assert what an image *without* an extension serves: no
# /buzz-launch, no Nostr card, no fountain-buzz row. Whether this VM is that
# image is decided by the invocation, not by the code. `config/runtime.exs`
# names each extension only where it loads, so `mix test` from apps/fountain —
# what scripts/test-partition.sh runs, and what CI is therefore green on —
# installs none, while `mix test` at the umbrella root, which CLAUDE.md's Quick
# start gives, has :fountain_buzz on the code path and installs it. Those five
# tests then described a distribution this VM is not, and the documented local
# command was red on a green `main`.
#
# Excluded rather than duplicated: the bundled side is asserted in
# apps/fountain_buzz/test/fountain_buzz/marketing_test.exs, which is the suite
# that has the extension. Appended to whatever is already excluded so a
# `--exclude` on the command line survives.
if Fountain.Extensions.installed?(:buzz) do
  ExUnit.configure(exclude: ExUnit.configuration()[:exclude] ++ [:core_distribution])
end

# The managoat_runner library has no config of its own and no default host on
# purpose; its own test helper names Managoat.Runner.Host.Local. While it was
# an umbrella app, `mix test` at the root ran its suite in this VM first and
# that value survived into Fountain's run, so Fountain's host is named again
# here. It is on hex now (#1345) and its suite no longer runs here, which
# makes this a no-op, kept for the day a library reappears under apps/.
# Same value as config/config.exs.
Application.put_env(:managoat_runner, :host, Fountain.Runners.Host)

# Extension fixtures describe OpenAPI paths only while the suite runs (ADR 0043,
# #1506). The published spec artifact is generated in MIX_ENV=test —
# `scripts/sdk-contract/build.sh` runs `mix openapi.export`, and both ci.yml and
# release.yml set MIX_ENV: test for it — so the `dist/openapi.json` attached to
# every tag, and `sdk/contract/contract.json` projected from it, would otherwise
# carry `/api/fixture/whoami` in every release. `mix openapi.export` is not a
# test run and never loads this file, which is exactly the distinction wanted:
# the fixture is part of the suite's distribution, not of the artifact's.
#
# A real extension is the opposite case and needs no flag — the bundled
# distribution serves its operations, so they belong in the artifact.
Application.put_env(:fountain, :extension_fixture_openapi, true)

# Only set sandbox mode when the Repo is actually running (integration tests).
# Pure unit tests that don't touch the DB can run without a live Postgres.
if Process.whereis(Fountain.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, :manual)
end

# Mimic copies modules so tests can stub/expect their functions. The sandbox
# seam is Managoat.Sandbox.Sprites (the adapter behind the Managoat.Sandbox
# facade, from the managoat_sandbox package); the raw SDK copies below exist for
# the full-stack provisioning/checkpoint pins. The adapters' own unit tests
# live in the library and copy what they stub in its test_helper.
Mimic.copy(Managoat.Sandbox)
Mimic.copy(Managoat.Sandbox.Sprites)
Mimic.copy(Fountain.AvatarGenerator)
Mimic.copy(Managoat.Sandbox.Sprites.Client)
Mimic.copy(Sprites)
Mimic.copy(Sprites.Filesystem)
Mimic.copy(Horde.DynamicSupervisor)
# Horde.Registry is copied so the registry settle window (#800) can be driven
# from a test rather than waited out: a stub decides which poll finds the
# server, which is what stops that test racing a loaded runner (#921).
Mimic.copy(Horde.Registry)
Mimic.copy(Req)
# Team stream tests observe real chunks and hold readiness frames until their
# publishers are done, before the controller starts its short idle timeout.
Mimic.copy(Plug.Adapters.Test.Conn)

# Stripe modules — needed by billing tests and webhook controller tests.
# Billing itself is copied so the webhook controller's :retry/500 arm can be
# driven with an injected transient failure — there is no real Stripe outage
# to reproduce in a test.
Mimic.copy(Fountain.Billing)
Mimic.copy(Stripe.Webhook)
Mimic.copy(Stripe.Customer)
Mimic.copy(Stripe.Checkout.Session)

Mimic.copy(Fountain.Conversations)
Mimic.copy(Fountain.Conversations.ExecutionAllowance)
Mimic.copy(Fountain.Conversations.ExecutionLimits)
Mimic.copy(Fountain.Conversations.Egress)
Mimic.copy(Fountain.Conversations.Lifecycle)
Mimic.copy(Fountain.Workers.WebhookDelivery)
Mimic.copy(Fountain.Conversations.ConversationServer)
Mimic.copy(Fountain.Conversations.TitleGenerator)
Mimic.copy(Fountain.Conversations.Provisioning)
Mimic.copy(Fountain.Broker)
Mimic.copy(Fountain.SandboxSkills)
Mimic.copy(Fountain.RuntimeDispatch)
Mimic.copy(Fountain.Accounts)
Mimic.copy(Fountain.Audit)
Mimic.copy(Fountain.Activation)
Mimic.copy(Fountain.Crypto)
Mimic.copy(Fountain.Health)
Mimic.copy(FountainWeb.OAuth)
Mimic.copy(Fountain.Mailer)
Mimic.copy(Fountain.InferenceCredentials)
Mimic.copy(Fountain.Workers.SandboxQueueDrainer)

# ─── The schema guard (#1427) ────────────────────────────────────────────────
#
# Every other check in this repository compares a schema with another schema.
# `sdk/contract` projects the OpenAPI document and pins four SDKs to it,
# `sdk/conformance` pins what those clients do with it, and both pass happily
# when the document is a lie about its own controller. Three defects of that
# shape surfaced in one day (#1417, #1418, #1427).
#
# This is the missing side of the comparison and it costs nothing per test:
# `Plug.Telemetry` is already in the endpoint, so every response any controller
# test produces is validated against the schema its operation declares. It
# records; `FountainWeb.ConnCase` fails the test that caused it. See the
# `attach/0` docstring for why it must not raise here.
FountainWeb.SchemaGuard.attach()
