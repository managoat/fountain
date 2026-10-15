# :live_adapter is test/live/: the pinned ACP adapters in a real sandbox, on
# real keys (#2670). It runs only when asked, with `--only live_adapter`.
ExUnit.start(exclude: [:live_adapter])

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
Mimic.copy(Managoat.Sandbox.Sprites.Client)
Mimic.copy(Sprites)
Mimic.copy(Sprites.Filesystem)
# The conversation and machine supervisors and registries are Elixir's own
# (ADR 0072). Copied so a test can stub a server's start or hide a registered
# one; `Fountain.ServerStart` is the usual way in.
Mimic.copy(DynamicSupervisor)
Mimic.copy(Registry)
Mimic.copy(Req)
# A sandbox-files read's cutoff must hold when its caller dies the moment its
# task starts (#2435 review). Stubbing `async_nolink` is the only way to kill
# the caller at exactly that point.
Mimic.copy(Task.Supervisor)
# SSE stream tests observe real chunks and hold readiness frames until their
# publishers are done, before the controller starts its short idle timeout.
Mimic.copy(Plug.Adapters.Test.Conn)

Mimic.copy(Fountain.Usage)

Mimic.copy(Fountain.Conversations)
Mimic.copy(Fountain.Conversations.Egress)
Mimic.copy(Fountain.Conversations.InferenceResolution)
Mimic.copy(Fountain.Conversations.Interruption)
Mimic.copy(Fountain.Conversations.Lifecycle)
Mimic.copy(Fountain.Conversations.Launch)
Mimic.copy(Fountain.Conversations.Wake)
Mimic.copy(Fountain.Conversations.Skills)
Mimic.copy(Fountain.Conversations.Termination)
Mimic.copy(Fountain.Conversations.ConversationServer)
Mimic.copy(Fountain.Conversations.Provisioning)
Mimic.copy(Fountain.Conversations.InferenceBinding)
Mimic.copy(Fountain.Quotas)
Mimic.copy(Fountain.Conversations.ProvisionWatchdog)
Mimic.copy(Fountain.Broker)
Mimic.copy(Fountain.SandboxSkills)
Mimic.copy(Fountain.RuntimeDispatch)
Mimic.copy(Managoat.Runtimes.Layout)
Mimic.copy(Fountain.Accounts)
Mimic.copy(Fountain.Audit)
Mimic.copy(Oban)
Mimic.copy(Fountain.Crypto)
Mimic.copy(Fountain.Health)
Mimic.copy(FountainWeb.OAuth)
Mimic.copy(Fountain.Mailer)
Mimic.copy(Fountain.InferenceCredentials)
# The machine owner's one write primitive (ADR 0058). Copied so a destroy's
# finalize can be handed a database fault — the `{:database, sqlstate}` shape
# `Lease.guarded/2` produces for #2309's `57014` — without one to reproduce.
Mimic.copy(Fountain.Machines.Lease)
# The protocol behind `Machine.destroy/2`, copied so the door's translation of
# its refusals into the system's vocabulary can be driven one shape at a time.
Mimic.copy(Fountain.Machines.Destroy)
# The same, for the third protocol (stage 7a): `Machine.ensure_up/2` lets more
# words through than either sibling — the fence, `:provisioning`, the provider's
# refusal and the admission's three — and each arm is driven by handing
# `Resume.run/2` one of them.
Mimic.copy(Fountain.Machines.Machine)
# The fifth protocol (stage 8a): `admission_test.exs` raises inside the owner
# to drive the door's answer for an owner that cannot serve the call.
Mimic.copy(Fountain.Machines.Admission)
Mimic.copy(Fountain.Machines.Binding)
Mimic.copy(Fountain.Machines.Provision)
Mimic.copy(Fountain.Machines.Resume)

# ─── The schema guard (#1427) ────────────────────────────────────────────────
#
# Every other check in this repository compares a schema with another schema.
# `sdk/contract` projects the OpenAPI document and pins the SDK to it,
# the SDK's wire scenarios pin what that client does with it, and both pass happily
# when the document is a lie about its own controller. Three defects of that
# shape surfaced in one day (#1417, #1418, #1427).
#
# This is the missing side of the comparison and it costs nothing per test:
# `Plug.Telemetry` is already in the endpoint, so every response any controller
# test produces is validated against the schema its operation declares. It
# records; `FountainWeb.ConnCase` fails the test that caused it. See the
# `attach/0` docstring for why it must not raise here.
FountainWeb.SchemaGuard.attach()
