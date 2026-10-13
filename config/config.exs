import Config

# Oban: durable background jobs. The Cron plugin elects a leader across the
# cluster itself, so scheduled work runs once regardless of replica count —
# the problem the Rehydrator solves by hand.
config :fountain, Oban,
  repo: Fountain.Repo,
  # chatgpt carries the pollers of users' ChatGPT sign-ins (ADR 0060 stage 4):
  # one short HTTP call to the auth server every few seconds per open attempt,
  # for at most fifteen minutes. Its own queue so a burst of sign-ins never
  # sits in front of a schedule or an email. Ten, because the queue serves
  # every account at once and a run is one or two HTTP calls and a short
  # write: it waits on the auth server, never on a CPU. Each call is bounded
  # at eighteen seconds (`OAuth.refresh_timeout_ceiling_ms/0`), so an auth
  # server that stops answering delays the other polls by seconds, and an
  # account's own three open attempts cannot fill it.
  # chatgpt_refresh carries the keepalive's renewals of users' idle ChatGPT
  # grants (ADR 0060 stage 5): one call to the auth server's token endpoint
  # per job, through `ChatGPTAccounts.RefreshCoordinator`. Two per node, on
  # purpose below the four renewals that coordinator admits, so a turn whose
  # grant needs renewing never finds the keepalive holding every slot. Not
  # on chatgpt, whose ten slots would let it.
  queues: [
    maintenance: 1,
    chatgpt: 10,
    chatgpt_refresh: 2,
    mailer: 5,
    schedules: 5
  ],
  plugins: [
    # Oban's own job-table pruning: completed jobs older than 7 days.
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    # Orphan rescue, required by the worker that carries `unique:` with
    # `states: :incomplete` — `SandboxReaper` (ADR 0058 stage 6b), both its
    # hourly run and its five-minute teardown run, which are unique apart
    # because their args differ. A job left `executing` by a pod that died
    # mid-run stays `executing` for ever, and for a unique worker that is not
    # one lost run: every later cron insert answers `conflict?: true` against
    # the corpse, and the sweep stops for good with nothing failing. Oban's
    # shutdown grace is 15 seconds and a contended reaper run is budgeted at
    # minutes, so the pod that loses a rolling deploy mid-sweep is the ordinary
    # case rather than a rare one.
    #
    # Rescued after 30 minutes, checked every minute: comfortably longer than
    # any run should take, and far shorter than the hour between crons, so a
    # rescue never overlaps the run it is standing in for. Thirty rather than
    # ten because `SandboxReaper`'s `@owner_attempt_limit` bounds its *owner
    # attempts* at about eight minutes and nothing else — a run also lists
    # every provider's sandboxes and spends its destroy budget on them, and a
    # slow provider is exactly the condition under which a long run and a
    # rescue would otherwise meet.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30), interval: :timer.minutes(1)},
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
       # Every 5 minutes: finish the destroys that were asked for and then
       # abandoned — a reset the provider never confirmed, a teardown whose
       # caller died (ADR 0058 stage 9b; `SandboxResetReconciler` did the
       # resets on this clock until then). An abandoned destroy holds the
       # tenant's quota slot and bills, so this is the reconciler's clock
       # rather than the hourly one.
       {"*/5 * * * *", Fountain.Workers.SandboxReaper, args: %{"pass" => "teardowns"}},
       # A server's autonomous quiet timer is in memory. Sweep old, silent
       # running turns whose server disappeared before that timer fired.
       {"*/5 * * * *", Fountain.Workers.AutonomousTurnReaper},
       # Every minute: deny permission requests that outlived their turn and
       # then ran out of time (#1635). Their deadline is on the turn row
       # rather than in a process timer, because the sandbox parks and the
       # server stops while such a request waits. One indexed query, usually
       # empty.
       {"* * * * *", Fountain.Workers.DetachedRequestSweeper},
       # 17:07 UTC — vault-secret expiry notices land mid-day for the US and
       # end-of-day for Europe, when someone is at a keyboard to rotate the
       # credential; the notice window is days wide, so the hour is about
       # being read, not about precision.
       {"7 17 * * *", Fountain.Workers.SecretExpirySweeper},
       # 04:29 UTC daily: renew the deployment's ChatGPT grant for codex if
       # nobody has for six days (ADR 0047), so it
       # never idles past the auth server's window. No-op when not connected.
       {"29 4 * * *", Fountain.Workers.PlatformChatGPTKeepalive},
       # 04:37 UTC daily: the same for users' grants (ADR 0060 stage 5). The
       # sweep only pages ids and queues one chatgpt_refresh job per idle
       # grant, spread over minutes to hours by how many are due; the jobs
       # make the calls. Empty when nobody has linked a subscription.
       {"37 4 * * *", Fountain.Workers.ChatGPTKeepaliveSweep},
       {"31 3 * * *", Fountain.Workers.BrokerReaper},
       # Every minute: the tick for user-defined team schedules. Cheap — one
       # indexed query, usually empty — and a minute is the cron grain the
       # schedules are written in.
       {"* * * * *", Fountain.Workers.TeamScheduler},
       # Five-minute backstop for the event-driven sandbox queue (ADR 0042).
       # Normal drains come from a sandbox leaving a cap-counting status; this
       # catches a lost poke and expires work that waited too long.
       {"*/5 * * * *", Fountain.Workers.SandboxQueueDrainer}
     ]}
  ]

# Self-hosting switches. runtime.exs overrides them from the environment.
config :fountain,
  registration_enabled: true,
  registration_allowed_email_domains: [],
  registration_access_code: nil

# Concurrency (ADR 0005, 0042). A tenant may run cap_ceiling sandboxes at
# once, or users.sandbox_limit_override when set. fleet_ceiling bounds the
# sum across every tenant to what the providers allow. runtime.exs overrides
# from SANDBOX_*.
config :fountain, :sandboxes,
  cap_ceiling: 20,
  fleet_ceiling: 20

# The bounded wait in front of those two ceilings (ADR 0042). Depth is per
# tenant; the wait bound is what stops a queued start outliving the intent
# behind its prompt.
config :fountain,
  sandbox_queue_max_depth: 10,
  sandbox_queue_max_wait_seconds: 3600

# How many ChatGPT subscriptions one account may link (ADR 0060 decision 1).
# It stops a runaway client; it does not price anything. Nothing links one
# yet, so there is no environment variable for it yet either.
config :fountain, :chatgpt_grant_ceiling, 5

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

# Request parameters Phoenix redacts from its debug `Parameters:` log line.
# Phoenix's own default is the first two; setting the key replaces it, so they
# stay. A key matches if it contains one of these, at any depth.
config :phoenix, :filter_parameters, ["password", "token", "access_code"]

# Swoosh mailer
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Local

# The API adapters (Resend) call out over Req. Swoosh defaults to hackney,
# which is not a dependency; without this the release dies at boot on
# "missing hackney dependency". dev and test turn it off.
config :swoosh, :api_client, Swoosh.ApiClient.Req

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

# The sandbox adapter map (Managoat.Sandbox, decisions/0037): the Sprites
# and E2B adapters the sandbox library ships (Fountain no longer uses its
# Daytona one) plus the self-hosted runner's, from the runner library
# (ADR 0022). Static, so it lives here rather than in
# runtime.exs. Which of these a deployment may *use* is
# Fountain.SandboxProviders' question; the library answers only which module
# serves a provider atom.
config :managoat_sandbox,
  adapters: %{
    sprites: Managoat.Sandbox.Sprites,
    e2b: Managoat.Sandbox.E2B,
    runner: Managoat.Runner.Adapter
  }

# What the runner library needs from this platform (Managoat.Runner.Host):
# the Horde registry, the last_seen_at stamp and the presence broadcast,
# all behind Fountain.Runners.Host. The library has no default host on
# purpose.
config :managoat_runner, host: Fountain.Runners.Host

import_config "#{config_env()}.exs"
