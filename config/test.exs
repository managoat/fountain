import Config

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
  # waits of 121-160 ms) and #1568 (the credit ledger's concurrent-post test,
  # 263 ms), neither of them a defect in the code under test.
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
# Tests start the coordinator explicitly with owned database fixtures.
config :fountain, :execution_deadline_worker_enabled, false
config :fountain, :checkpoint_creation_enabled, false
config :managoat_sandbox, Managoat.Sandbox.Sprites, checkpoint_creation_enabled: false

# Skip the Ueberauth plug so tests can set :ueberauth_auth/:ueberauth_failure
# directly without triggering a real OAuth network round-trip.
config :fountain, :ueberauth_test_mode, true

# A fake client id so FountainWeb.OAuth.github_configured?/0 is true and the
# "Continue with GitHub" button renders in tests (#336). Inert: the test mode
# above means no real OAuth round-trip ever happens.
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "test-github-client-id",
  client_secret: "test-github-client-secret"

# The runtime CREDITS_ENABLED switch defaults to off (#336) but is not applied
# in :test (see config/runtime.exs) — the suite pins the gate on here and
# toggles it per-test via the application env.
config :fountain, :credits_enabled, true

# `/` serves the marketing page in :test (MARKETING_SITE is not read in :test —
# see config/runtime.exs), so the existing homepage tests keep covering the
# pitch. The plain front door is covered by flipping this off per-test.
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

# A known webhook secret so StripeWebhookController's fail-closed secret
# resolution (#390) succeeds; signature-path tests sign payloads with the
# value they read back from this key, exercising the real construct_event.
config :stripity_stripe, webhook_secret: "whsec_test_signing_secret"

# Key rate limit buckets by calling process PID instead of IP, so async
# ExUnit tests don't share counters. Each test runs in its own process.
config :fountain, :rate_limit_test_isolation, true

# The funnel telemetry poller queries the DB outside any test's SQL Sandbox
# ownership; keep it off here (Fountain.Funnel is tested directly).
config :fountain, :funnel_poller_enabled, false

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

# Teammate email + phone (flag `team_comms`) and the PostHog flag lookup:
# every outbound call goes to a Req.Test plug, so a test that forgets to
# stub fails loudly instead of reaching a real provider. The keys are set so
# `Comms.configured?/0` holds; the flag itself stays off (no override, no
# PostHog key) until a test flips `:feature_flag_overrides`.
config :fountain, :agentmail_api_key, "am_test_key"
config :fountain, :agentmail_req_options, plug: {Req.Test, Fountain.Team.Comms.AgentMail}
config :fountain, :agentphone_api_key, "ap_test_key"
config :fountain, :agentphone_req_options, plug: {Req.Test, Fountain.Team.Comms.AgentPhone}
config :fountain, :agentphone_webhook_secret, "whsec_test"
config :fountain, :posthog_req_options, plug: {Req.Test, Fountain.FeatureFlags}

# Connections (#1178, #1299): every platform OAuth client set so the flows
# are "configured", and Req.Test plugs so no test reaches a provider. Same
# failure mode as AgentMail above: an unstubbed call fails loudly.
config :fountain, :google_oauth_client_id, "google-test-client-id"
config :fountain, :google_oauth_client_secret, "google-test-client-secret"
config :fountain, :microsoft_oauth_client_id, "microsoft-test-client-id"
config :fountain, :microsoft_oauth_client_secret, "microsoft-test-client-secret"
config :fountain, :slack_oauth_client_id, "slack-test-client-id"
config :fountain, :slack_oauth_client_secret, "slack-test-client-secret"
config :fountain, :connections_req_options, plug: {Req.Test, Fountain.Connections.OAuth}
# The ChatGPT grant for codex (ADR 0047): every call to auth.openai.com goes to
# a Req.Test plug, so a test that forgets to stub it fails rather than dialling
# out.
config :fountain, :platform_chatgpt_req_options, plug: {Req.Test, Fountain.PlatformChatGPT.OAuth}
# Discovery and the OAuth client refuse private hosts; the Req.Test stub
# answers for any host, so the resolution check is off here (#1186).
config :managoat_mcp_auth, :req_options, plug: {Req.Test, Fountain.Connections.OAuth}
config :managoat_mcp_auth, :allow_private_hosts, true
config :fountain, :gmail_req_options, plug: {Req.Test, Fountain.Connections.Gmail}

# Product analytics (`Fountain.Analytics`). Capture is inert without a project
# API key, which the suite deliberately does not set — so the default here is
# "nothing is sent", and a test that wants to assert on a payload sets the key
# and stubs the plug. `:inline` sends from the calling process so the stub is
# owned by the test that installed it, exactly as the flag lookup is.
config :fountain, :analytics_mode, :inline
config :fountain, :analytics_req_options, plug: {Req.Test, Fountain.Analytics}
config :fountain, :analytics_instance, "test"

# Webhooks (#700). Every delivery goes to a Req.Test plug, so a test that
# forgets to stub fails loudly instead of reaching a real receiver. `http://`
# endpoints are permitted here so a test can use a plain URL; the SSRF guard
# is unaffected by that flag and is exercised directly in
# `webhooks/url_test.exs`.
config :fountain, :webhook_req_options, plug: {Req.Test, Fountain.Webhooks}
config :fountain, :webhook_allow_http, true
config :fountain, :webhooks_enabled, true

# Extensions (ADR 0043) are assembled in `config/runtime.exs`, not here.
#
# `Code.ensure_loaded?/1` is the only way to ask whether a sibling app is on
# this run's code path — `apps/fountain` depends on none of them, so running
# from there (which is what CI's partition script does) must install none — and
# that question can only be answered AFTER compilation. This file is evaluated
# before it, where the answer is always false. `runtime.exs` runs after, in
# every entry point, so the whole list is built there in one place: fixtures for
# the suite, plus the Buzz extension where it loads.
#
# `config :fountain, :extensions` REPLACES the key rather than appending, which
# is why it must be one declaration and not two — two silently deleted the
# fixtures and made the seam's own tests measure an empty list.
