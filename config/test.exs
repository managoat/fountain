import Config

# Fixture password hashes share the dirty CPU schedulers with MDEx and Lumis.
# Production-cost hashes can starve the docs guardrails past their timeout
# (#1701). Keep real hashing and verification at bcrypt's recommended test cost.
config :bcrypt_elixir, :log_rounds, 4

config :fountain, Fountain.Repo,
  url:
    System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/fountain_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 20,
  # The sandbox gives a test *one* connection, which every process the test
  # fans work out to shares: `Task.async_stream` in a test body, a supervised
  # task under `Fountain.TaskSupervisor`, and Ecto's own parallel preloader,
  # which fans out over `Task.async_stream` whenever two or more associations
  # are still to fetch. Those are not parallel under the sandbox — they are a
  # queue on one connection, and four 200 ms transactions measured 814 ms.
  #
  # DBConnection then drops a waiter once the queue has been slow for a whole
  # `queue_interval`, and the 50 ms / 1 s defaults are sized for a pool with
  # spare connections rather than for a queue that is a queue by construction.
  # On a loaded workstation that dropped real tests: #1524 (Ecto's preloader,
  # waits of 121-160 ms) and #1568 (a concurrent-post test, 263 ms), neither of them a defect in the code under test.
  #
  # 200 ms / 5 s tolerates about 5 s of continuous backlog on one connection,
  # against the ~250 ms the real failures waited. A genuinely stuck connection
  # still surfaces — as the test's own timeout, with the stack of whatever is
  # holding it, which says more than a dropped checkout does. Measured with a
  # 40-task probe: 30 of 40 dropped at the defaults, 0 of 40 here.
  queue_target: 200,
  queue_interval: 5_000

config :fountain, FountainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "c4S1HEBb+LhhInAgMbEJdXVBSKK65S7Mk9oeXrPTn65slnwVQU5zFqCT3p2wqWaR",
  server: false

config :fountain, :skip_rehydrate, true

# The machine owner (ADR 0058) serves each call as its caller, so a test's SQL
# sandbox connection and Mimic stubs reach it. Test-only by design: production
# must not put `$callers` in the owner (`Fountain.Machines.Machine.handle_call/3`
# says why).
config :fountain, :owner_adopts_callers, true
# Tests start the coordinator explicitly with owned database fixtures.
config :fountain, :execution_deadline_worker_enabled, false
config :fountain, :checkpoint_creation_enabled, false
config :managoat_sandbox, Managoat.Sandbox.Sprites, checkpoint_creation_enabled: false
# A park's snapshot of the disk (ADR 0063) runs two scripts on the machine;
# the suites that want one turn it on, and the rest park without it.
config :fountain, Fountain.SandboxFiles.Snapshots, enabled: false

# Skip the Ueberauth plug so tests can set :ueberauth_auth/:ueberauth_failure
# directly without triggering a real OAuth network round-trip.
config :fountain, :ueberauth_test_mode, true

# A fake client id so FountainWeb.OAuth.github_configured?/0 is true and the
# "Continue with GitHub" button renders in tests (#336). Inert: the test mode
# above means no real OAuth round-trip ever happens.
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "test-github-client-id",
  client_secret: "test-github-client-secret"

# The public chrome links the marketing site's pages in :test (MARKETING_SITE
# is not read in :test — see config/runtime.exs); the chrome without them is
# covered by flipping this off per-test.
config :fountain, :marketing_site, true

# Legal identity pinned (LEGAL_* env vars are not read in :test — see
# config/runtime.exs) so the developer's shell can't change suite behavior;
# unpublished-page tests set :legal to nil through the application env.
config :fountain, :legal, %{
  entity: "Test Legal Entity LLC",
  contact_email: "legal@example.com",
  jurisdiction: "the State of Testing",
  updated: "2026-01-01"
}

# A per-account cap well under the fleet ceiling, so a test that fills one
# account's cap meets the account's refusal (429) rather than the fleet's (503).
config :fountain, :sandboxes, cap_ceiling: 2, fleet_ceiling: 20

# Key rate limit buckets by calling process PID instead of IP, so async
# ExUnit tests don't share counters. Each test runs in its own process.
config :fountain, :rate_limit_test_isolation, true

# The gauge telemetry poller queries the DB outside any test's SQL Sandbox
# ownership; keep it off here (Fountain.OpsGauges is tested directly).
config :fountain, :gauge_poller_enabled, false

# Managoat.Sandbox.Retry sleeps between attempts; 1ms keeps retry-path tests
# fast without changing the retry logic under test.
config :managoat_sandbox, Managoat.Sandbox.Retry, base_ms: 1

# The registry settle window (#800) is a real-time wait; keep tests brisk.
config :fountain, :conversation_registry_settle_ms, 150

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

# Swoosh test adapter — use Swoosh.TestAssertions in tests
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

# Pinned so a developer's shell (EMAIL_DELIVERY / FIRST_USER_ADMIN /
# MIGRATE_ON_BOOT) can't change suite behavior; tests toggle these through
# the application env.
config :fountain, :email_enabled, true
config :fountain, :first_user_admin, false
config :fountain, :migrate_on_boot, true

# Jobs are asserted with Oban.Testing rather than executed as a side effect.
config :fountain, Oban, testing: :manual

# OAuth clients (#818) the controller tests register against.
config :fountain, Fountain.OAuth,
  clients: [
    %{
      id: "test-app",
      name: "Test App",
      redirect_uris: ["https://app.test/callback", "http://localhost:5173/"]
    }
  ]

# Self-hosted runners (ADR 0022) are enabled by default in every other env —
# there is no credential to be missing. Off here so the suite's assumptions
# about "which providers are enabled" (only what a test configures) hold;
# runner tests switch it on explicitly.
config :fountain, :runners_enabled, false

# The ChatGPT grant for codex (ADR 0047): every call to auth.openai.com goes to
# a Req.Test plug, so a test that forgets to stub it fails rather than dialling
# out.
config :fountain, :platform_chatgpt_req_options, plug: {Req.Test, Fountain.PlatformChatGPT.OAuth}
# `ChatGPTAccounts.RefreshBreaker` reads a test's clock
# (`:chatgpt_refresh_breaker_now_ms`) only in a build compiled with this.
config :fountain, :chatgpt_refresh_breaker_test_clock, true
