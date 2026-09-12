import Config

# Oban: durable background jobs. The Cron plugin elects a leader across the
# cluster itself, so scheduled work runs once regardless of replica count —
# the problem the Rehydrator solves by hand.
config :fountain, Oban,
  repo: Fountain.Repo,
  # exports is its own queue so a user-requested data export is never stuck
  # behind a maintenance sweep; concurrency 1 because each job reads every row
  # an account owns and two at once doubles that memory.
  # webhooks is its own queue so a tenant's slow receiver never sits in front
  # of a maintenance sweep or an email, and so its concurrency can be tuned
  # against outbound HTTP rather than against database work (#700).
  queues: [
    maintenance: 1,
    credits: 5,
    exports: 1,
    mailer: 5,
    schedules: 5,
    webhooks: 10,
    chatgpt_refresh: 4
  ],
  plugins: [
    # Oban's own job-table pruning: completed jobs older than 7 days.
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       # 04:23 UTC — after the 03:17 database backup, so pruning never races
       # the dump and a backup always captures the pre-prune state.
       {"23 4 * * *", Fountain.Workers.RetentionPruner},
       # Hourly: a leaked sprite costs money and a stuck sandbox row holds
       # tenant quota, so the gap between the leak and its cleanup is what
       # matters. Each run is one paginated list plus at most a handful of
       # deletes.
       {"7 * * * *", Fountain.Workers.SandboxReaper},
       # A server's autonomous quiet timer is in memory. Sweep old, silent
       # running turns whose server disappeared before that timer fired.
       {"*/5 * * * *", Fountain.Workers.AutonomousTurnReaper},
       # Every minute: deny permission requests that outlived their turn and
       # then ran out of time (#1635). Their deadline is on the turn row
       # rather than in a process timer, because the sandbox parks and the
       # server stops while such a request waits. One indexed query, usually
       # empty.
       {"* * * * *", Fountain.Workers.DetachedRequestSweeper},
       # Every 5 minutes: expire claimable principals nobody claimed (ADR
       # 0044). Latency here is money — an expired principal is a sprite still
       # running for a visitor who has gone — so the sweep runs on the same
       # grain as the turn reaper rather than daily with the other pruners.
       {"*/5 * * * *", Fountain.Workers.ClaimablePrincipalSweep},
       # An installed extension may add entries here at boot
       # (`Fountain.Extensions.oban_options/1`, ADR 0043). They are not listed
       # in this file, so a core-only release never names a worker module it
       # does not carry — which would be a crash on start, not a missing
       # feature.
       # 05:41 UTC — after the 03:17 backup and the 04:23 retention prune, so
       # a backup always captures the accounts before the sweep removes them.
       {"41 5 * * *", Fountain.Workers.UnverifiedAccountPruner},
       # 17:07 UTC — vault-secret expiry notices land mid-day for the US and
       # end-of-day for Europe, when someone is at a keyboard to rotate the
       # credential; the notice window is days wide, so the hour is about
       # being read, not about precision.
       {"7 17 * * *", Fountain.Workers.SecretExpirySweeper},
       # 04:29 UTC daily: renew the deployment's ChatGPT grant for codex if
       # nobody has for PLATFORM_CHATGPT_KEEPALIVE_DAYS (ADR 0047), so it
       # never idles past the auth server's window. No-op when not connected.
       {"29 4 * * *", Fountain.Workers.PlatformChatGPTKeepalive},
       # Bounded user-grant pages; provider calls run in a separate queue so
       # an unavailable auth server cannot hold up maintenance. The existing
       # keepalive timing is provisional, pending the ADR 0047 measurement.
       {"37 4 * * *", Fountain.Workers.ChatGPTKeepaliveSweep},
       {"31 3 * * *", Fountain.Workers.BrokerReaper},
       # Every minute: the tick for user-defined team schedules. Cheap — one
       # indexed query, usually empty — and a minute is the cron grain the
       # schedules are written in.
       {"* * * * *", Fountain.Workers.TeamScheduler},
       # Every 10 minutes: price closed turns and comms messages into the
       # credit ledger (ADR 0030) and sweep expired grants. Idempotent per
       # turn, per event and per grant, so the cadence only sets how stale a
       # balance can read. No-ops with billing off.
       {"*/10 * * * *", Fountain.Workers.CreditPricer},
       # 06:23 UTC daily: the expiry sweep on its own, as a backstop for the
       # pricer's tick (ADR 0030 decision 2). Idempotent per grant.
       {"23 6 * * *", Fountain.Workers.CreditExpirer},
       # 06:47 UTC daily: rent for numbers and inboxes, the grace reminders,
       # and the release on day seven (ADR 0030 decision 4). No-ops until a
       # rent price is set.
       {"47 6 * * *", Fountain.Workers.CreditRentCollector},
       # Five-minute backstop for the event-driven sandbox queue (ADR 0042).
       # Normal drains come from a sandbox leaving a cap-counting status; this
       # catches a lost poke and expires work that waited too long.
       {"*/5 * * * *", Fountain.Workers.SandboxQueueDrainer}
     ]}
  ]

# Self-hosting switches. In dev and prod, runtime.exs overrides credits from
# CREDITS_ENABLED — off unless set (#336); the hosted deployment opts in via
# the hosted overlay. The `true` here reaches only :test (runtime.exs skips
# the override there), where config/test.exs also pins it, so the suite
# exercises the gate as enforced and flips it off per-test.
config :fountain,
  credits_enabled: true,
  registration_enabled: true,
  registration_allowed_email_domains: [],
  # Which page `/` serves. False everywhere but the hosted deployment, which
  # opts in with MARKETING_SITE (runtime.exs); config/test.exs pins it true so
  # the suite covers the pitch and flips it off per-test. See Fountain.Marketing.
  marketing_site: false

# Concurrency (ADR 0031). A tenant may run as many sandboxes at once as
# their balance funds: clamp(balance / reserve_cents, cap_floor, cap_ceiling),
# with users.sandbox_limit_override winning when set. fleet_ceiling bounds
# the sum across every tenant to what the providers allow. runtime.exs
# overrides from SANDBOX_*.
# Teammate contacts a tenant may hold at once — an abuse ceiling, not a price.
config :fountain, :team_contact_ceiling, 10

# Hosted Buzz agents a tenant may run at once. Each enabled identity is a
# supervised `buzz-acp` OS process on Fountain's own pods (ADR 0020), so the
# cost is standing rather than metered — no sandbox meter sees it. An abuse
# ceiling, not an allowance (#1017).
config :fountain_buzz, :buzz_identity_ceiling, 10

config :fountain, :sandboxes,
  reserve_cents: 200,
  cap_floor: 2,
  cap_ceiling: 20,
  fleet_ceiling: 20

# The bounded wait in front of those two ceilings (ADR 0042). Depth is per
# tenant; the wait bound is what stops a queued start outliving the intent
# behind its prompt.
config :fountain,
  sandbox_queue_max_depth: 10,
  sandbox_queue_max_wait_seconds: 3600

# Prepaid credits (ADR 0030). Cents. `turn_hour_cents` is the customer price
# of one hour of turn time; the comms prices are nil until an operator sets
# them, and nil burns nothing (#1042). runtime.exs overrides from CREDIT_*.
config :fountain, :credits,
  # The opening grant a new account gets (ADR 0031 decision 3), and how
  # long it lasts.
  opening_cents: 500,
  opening_days: 14,
  turn_hour_cents: 25,
  number_cents: nil,
  inbox_cents: nil,
  email_message_cents: nil,
  sms_message_cents: nil,
  packs_cents: [1_000, 2_500, 10_000]

# Claimable principals (ADR 0044): the anonymous tenant an application opens
# for a visitor who has no account yet. Every number here bounds a leaked
# application key; the application's own credit balance is the backstop
# underneath them, since it funds each principal it opens.
config :fountain, Fountain.Principals,
  default_ttl_seconds: 86_400,
  max_ttl_seconds: 604_800,
  max_grant_cents: 500,
  max_outstanding_per_application: 500,
  max_created_per_hour: 500,
  purge_after_days: 7

# Sandbox lifetime bounds. Crossing the idle bound SUSPENDS the sandbox — the
# sprite stays (scaled to zero) and the next prompt resumes the agent with its
# memory intact, so this bound is free to be aggressive. The max-lifetime
# ceiling is OFF by default (#936): a tenant who wants a machine running
# 24/7 is not something to stop. Set it to bound a continuous run; crossing
# it parks a persistent home and destroys an ephemeral sprite, and the
# agent's session with it (#649). 0 disables either bound. See
# Fountain.Conversations.Lifecycle and decisions/0017.
config :fountain,
  sandbox_idle_timeout_minutes: 60,
  sandbox_max_lifetime_hours: 0

config :fountain,
  ecto_repos: [Fountain.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Take the migration lock as a Postgres advisory lock rather than Ecto's
# default `FOR UPDATE` on `schema_migrations` (#610). The default cannot
# serialize the one moment that matters: on a virgin database the table it
# locks does not exist yet, so two replicas booting together both reach
# `CREATE TABLE schema_migrations` and the loser dies on the type's unique
# index. An advisory lock is taken before anything touches the table, so the
# bootstrap is serialized like every migration after it.
config :fountain, Fountain.Repo, migration_lock: :pg_advisory_lock

# Whether a booting release runs pending migrations before it serves. True
# here so the shipped single-replica image needs no configuration;
# runtime.exs turns it off for MIGRATE_ON_BOOT=false, the deployment that
# runs migrations once in a Job instead. See Fountain.Release.migrate_on_boot/0.
config :fountain, :migrate_on_boot, true

config :fountain, FountainWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: FountainWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Fountain.PubSub,
  live_view: [signing_salt: "DtUggWta"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :remote_ip, :api_key]

config :phoenix, :json_library, Jason

# Swoosh mailer
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Local

# Whether this instance can deliver email at all. Flipped to false only by
# EMAIL_DELIVERY=none in runtime.exs; registration auto-verifies accounts when
# it is false, because a verification link that cannot be delivered gates
# nothing.
config :fountain, :email_enabled, true

# Self-host bootstrap (ADR 0011): when true, the first account to become
# verified on an instance with no admin is promoted to admin. Off everywhere
# unless FIRST_USER_ADMIN=true is set at boot.
config :fountain, :first_user_admin, false

# Ueberauth — GitHub OAuth strategy.
# `base_path` matches the router prefix in router.ex (`/auth/oauth/:provider`);
# without it the plug ignores the requests and the controller's :request
# action runs directly, redirecting users back to /auth/login.
config :ueberauth, Ueberauth,
  base_path: "/auth/oauth",
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_OAUTH_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_OAUTH_CLIENT_SECRET")

# OAuth (#818, #1305): Fountain.OAuth is an instance of Managoat.OAuth
# (decisions/0037). The library reads its repo and the public-client registry
# from here, under the instance module, never from :fountain directly. No
# clients by default; dev/test/runtime set them.
config :fountain, Fountain.OAuth, repo: Fountain.Repo, clients: []

# The sandbox adapter map (Managoat.Sandbox, decisions/0037): the three
# adapters the sandbox library ships plus the self-hosted runner's, from the
# runner library (ADR 0022). Static, so it lives here rather than in
# runtime.exs. Which of these a deployment may *use* is
# Fountain.SandboxProviders' question; the library answers only which module
# serves a provider atom.
config :managoat_sandbox,
  adapters: %{
    sprites: Managoat.Sandbox.Sprites,
    e2b: Managoat.Sandbox.E2B,
    daytona: Managoat.Sandbox.Daytona,
    runner: Managoat.Runner.Adapter
  }

# What the runner library needs from this platform (Managoat.Runner.Host):
# the Horde registry, the last_seen_at stamp and the presence broadcast,
# all behind Fountain.Runners.Host. The library has no default host on
# purpose.
config :managoat_runner, host: Fountain.Runners.Host

import_config "#{config_env()}.exs"
