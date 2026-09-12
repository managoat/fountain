defmodule FountainWeb.Telemetry do
  @moduledoc false
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
        {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics()}
      ] ++ metrics_server()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Metrics are served on their own port, never through the Phoenix endpoint.
  # The Traefik IngressRoute matches on Host with no path predicate, so anything
  # mounted on the endpoint is public — including request rates, route names and
  # DB timings. The scrape port is reachable only from inside the cluster.
  #
  # nil port disables the server entirely, which is the default in dev and test
  # so a stray listener can't collide with concurrent runs.
  defp metrics_server do
    case Application.get_env(:fountain, :metrics_port) do
      nil -> []
      port -> [{Bandit, plug: FountainWeb.MetricsPlug, scheme: :http, port: port}]
    end
  end

  @doc """
  Metrics exported to Prometheus.

  Deliberately a separate list from `metrics/0`. That one is built for
  LiveDashboard and is all `summary/2`, which the Prometheus core reporter does
  not implement — wiring it up directly raises at boot. Prometheus wants
  `distribution` (histogram), `counter`, `sum` and `last_value`.

  Bucket boundaries are in milliseconds and chosen around what matters here:
  sub-100ms is a healthy page render, and the tail past 1s is what a user
  actually notices.
  """
  def prometheus_metrics do
    [
      # ── HTTP ──────────────────────────────────────────────────────────────
      distribution("phoenix.router_dispatch.stop.duration",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:route, :method, :status],
        tag_values: &http_tags/1,
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]],
        description: "HTTP request duration by route, method and status"
      ),
      counter("phoenix.router_dispatch.stop.count",
        event_name: [:phoenix, :router_dispatch, :stop],
        tags: [:route, :method, :status],
        tag_values: &http_tags/1,
        description: "HTTP requests by route, method and status"
      ),
      # Exceptions that escape the router. This is the closest thing to an
      # error-rate signal until real error tracking lands.
      counter("phoenix.router_dispatch.exception.count",
        event_name: [:phoenix, :router_dispatch, :exception],
        tags: [:route, :kind],
        tag_values: &exception_tags/1,
        description: "Unhandled exceptions by route"
      ),

      # ── Database ──────────────────────────────────────────────────────────
      distribution("fountain.repo.query.total_time",
        event_name: [:fountain, :repo, :query],
        measurement: :total_time,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]],
        description: "Ecto query duration"
      ),
      # Queue time is the pool-saturation signal: it climbs when every
      # connection is checked out, which is the failure that looks like "the
      # whole app got slow" rather than "one query got slow".
      distribution("fountain.repo.query.queue_time",
        event_name: [:fountain, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 500]],
        description: "Time waiting for a database connection from the pool"
      ),

      # ── Conversations ─────────────────────────────────────────────────────
      # These are the domain events that cost money and wake people up.
      #
      # The counter hangs off the [:fountain, :stage] event that
      # Conversations.publish_stage/4 emits — the same funnel that feeds the
      # client-visible stage stream. Provision/reattach/turn failures are
      # handled inside the GenServer (rescued, mapped to "failed" stages), so
      # a span :exception event never fires for them; counting stages is the
      # only wiring that sees every outcome. Tags are bounded: stage is a
      # fixed set of pipeline step names, status is
      # started/done/failed/interrupted.
      counter("fountain.stage.count",
        event_name: [:fountain, :stage],
        tags: [:stage, :status],
        description: "Conversation stage transitions by stage and status"
      ),
      # Any non-zero value here means a privilege-trail row was silently
      # dropped (#451) — alert-worthy, not informational.
      counter("fountain.audit.admin_record_rejected.count",
        event_name: [:fountain, :audit, :admin_record_rejected],
        tags: [:event_type],
        description: "Admin audit events rejected at write time (lost trail rows)"
      ),
      # The only signal that two servers raced for the same ChatGPT grant's
      # refresh. Contention is expected and harmless; a rate that climbs with
      # replica count is how "the lock is doing real work" becomes visible.
      counter("fountain.chatgpt.refresh_lock.contention.count",
        event_name: [:fountain, :chatgpt, :refresh_lock, :contention],
        description: "Refreshers that found another node holding the grant lock"
      ),
      # Any non-zero value here means billing data is being lost (#503) —
      # record_usage/5 swallows failures by contract, so this counter is the
      # only signal that distinguishes "no usage" from "metering broken".
      counter("fountain.usage.dropped.count",
        event_name: [:fountain, :usage, :dropped],
        tags: [:event_type, :kind],
        description: "Usage events dropped at write time (lost billing data)"
      ),
      distribution("fountain.fresh_provision.stop.duration",
        event_name: [:fountain, :fresh_provision, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long a fresh sandbox takes to provision"
      ),
      distribution("fountain.reattach.stop.duration",
        event_name: [:fountain, :reattach, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long a sandbox reattach takes"
      ),

      # How long a turn takes end to end (#536). Until this, turn duration
      # existed only as a `fountain.turn` OTel span (traces, and only with
      # OTLP export configured) and as turns.started_at/ended_at in Postgres
      # (queryable by hand, not trended). fountain.stage.count already covers
      # turn rates and outcomes — this is the duration.
      #
      # ConversationServer emits it from every path that ends a turn which
      # ran; a turn resumed after a restart contributes no sample, since its
      # start is in a previous BEAM lifetime.
      #
      # Buckets go much further out than the provision ones: a provision that
      # takes 2 minutes is broken, a turn that takes 20 is a Tuesday.
      distribution("fountain.turn.completed.duration_ms",
        event_name: [:fountain, :turn, :completed],
        measurement: :duration_ms,
        tags: [:runtime, :status, :provider],
        reporter_options: [
          buckets: [1000, 5000, 15_000, 30_000, 60_000, 120_000, 300_000, 600_000, 1_800_000]
        ],
        description: "Turn duration by runtime, provider and terminal status"
      ),
      # Time to first token (#535) — the latency between hitting enter and
      # seeing the agent do something, which is the one a user actually
      # feels. Turn duration above says how long the whole thing took; this
      # says how long it took to start.
      #
      # Buckets are much tighter than the turn ones on purpose: past ~30s of
      # silence the user has already concluded it's broken, so resolution
      # below that is where the signal is.
      #
      # Runtime-agnostic — ConversationServer measures the first stdout
      # bytes, not parsed tokens, so claude/codex/gemini/opencode are all
      # comparable here.
      distribution("fountain.turn.first_output.elapsed_ms",
        event_name: [:fountain, :turn, :first_output],
        measurement: :elapsed_ms,
        tags: [:runtime, :provider],
        reporter_options: [buckets: [250, 500, 1000, 2500, 5000, 10_000, 30_000, 60_000]],
        description: "Time from turn start to the sandbox's first output byte"
      ),

      # ── Provisioning sub-steps (#537) ─────────────────────────────────────
      # The two spans above answer "did provisioning get slower"; these answer
      # "which step". All six were already emitting :stop events with a
      # duration — they just went nowhere but the JSON log and OTel, so a
      # regression in the provision histogram meant grepping log lines or
      # opening individual traces to find the culprit.
      #
      # Same buckets as fresh_provision on purpose: these are its components,
      # so shared boundaries make them comparable at a glance. 120s is also
      # exactly the setup-script timeout, so the top bucket is that ceiling.
      #
      # No tags. The span metadata carries conv_id / env_id / checkpoint_id,
      # and every one of those would mint a time series per conversation.
      distribution("fountain.setup_script.stop.duration",
        event_name: [:fountain, :setup_script, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long an environment's setup script takes"
      ),
      distribution("fountain.packages.stop.duration",
        event_name: [:fountain, :packages, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long package installation takes"
      ),
      distribution("fountain.network_policy.stop.duration",
        event_name: [:fountain, :network_policy, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long applying the sprite network policy takes"
      ),
      distribution("fountain.clone_repositories.stop.duration",
        event_name: [:fountain, :clone_repositories, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long cloning an environment's repositories takes"
      ),
      distribution("fountain.checkpoint.create.stop.duration",
        event_name: [:fountain, :checkpoint, :create, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long creating an environment checkpoint takes"
      ),
      distribution("fountain.checkpoint.restore.stop.duration",
        event_name: [:fountain, :checkpoint, :restore, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long restoring an environment checkpoint takes"
      ),

      # ── Lifecycle sweeps ──────────────────────────────────────────────────
      counter("fountain.sandbox.reclaimed.count",
        event_name: [:fountain, :sandbox, :reclaimed],
        description: "Sandboxes destroyed by the max-lifetime ceiling"
      ),
      counter("fountain.sandbox.suspended.count",
        event_name: [:fountain, :sandbox, :suspended],
        description: "Sandboxes parked by the idle bound (sprite kept, decisions/0017)"
      ),
      # ── The bounded capacity queue (ADR 0042) ──────────────────────────
      #
      # Depth is observed after every queue mutation rather than polled, so a
      # spike between two poller ticks is still in the histogram.
      distribution("fountain.sandbox_queue.tenant_depth",
        event_name: [:fountain, :sandbox_queue, :tenant_depth],
        measurement: :depth,
        reporter_options: [buckets: [0, 1, 2, 3, 5, 8, 10]],
        description: "Live sandbox requests for a tenant, after a queue mutation"
      ),
      counter("fountain.sandbox_queue.completed.count",
        event_name: [:fountain, :sandbox_queue, :completed],
        measurement: :count,
        tags: [:status, :kind],
        description: "Sandbox requests that reached a terminal outcome, by outcome and kind"
      ),
      # The number that says whether the queue is a wait or a black hole, and
      # the evidence for revisiting the one-hour bound.
      distribution("fountain.sandbox_queue.completed.wait_ms",
        event_name: [:fountain, :sandbox_queue, :completed],
        measurement: :wait_ms,
        tags: [:status, :kind],
        reporter_options: [
          buckets: [1000, 5000, 15_000, 30_000, 60_000, 300_000, 900_000, 1_800_000, 3_600_000]
        ],
        description: "How long a sandbox request waited before its terminal outcome"
      ),
      # ── Credits and billing (#1169) ────────────────────────────────────
      #
      # ADR 0031 makes the balance the gate, so these workers are load-bearing
      # and none of them was watched: `FountainObanJobsRaising` needs a job to
      # *raise*, and a pricer that runs and prices nothing never does. Two
      # separate questions, deliberately — see Fountain.Credits.Telemetry.
      #
      # "Did it run?" A wall-clock stamp, so a rule can alert on staleness and
      # on a worker that never fires at all. PER-REPLICA: the stamp exists only
      # on the pod that ran the Oban job, so every rule over it needs `max`.
      last_value("fountain.credits.worker.run.last_run_unix",
        event_name: [:fountain, :credits, :worker, :run],
        measurement: :last_run_unix,
        tags: [:worker],
        description: "Unix time of the last completed pass, per credit worker"
      ),
      sum("fountain.credits.worker.run.total",
        event_name: [:fountain, :credits, :worker, :run],
        measurement: :total,
        tags: [:worker],
        description: "Ledger rows written per credit worker pass"
      ),
      # "Did money move?" From the ledger write itself, so it cannot drift
      # from the ledger. `reason` is a closed vocabulary, so this is the whole
      # answer for turns, inference, messages, rent, expiry and purchases —
      # and a burn_turn total of zero over a day while turns complete is the
      # signal that the pricer is broken rather than idle.
      sum("fountain.credits.posted.cents",
        event_name: [:fountain, :credits, :posted],
        measurement: :cents,
        tags: [:reason, :direction],
        description: "Cents moved through the credit ledger, by reason"
      ),
      counter("fountain.stripe_webhook.failure.count",
        event_name: [:fountain, :stripe_webhook, :failure],
        tags: [:kind],
        description: "Stripe webhooks rejected or failed, by coarse kind"
      ),
      # Swoosh already spans every delivery, so this needs no call-site change
      # across the fourteen `Mailer.deliver/1` sites. A failed credit or
      # verification email is a customer who never learns their balance ran
      # out, which until now was visible in a log line and nowhere else.
      counter("fountain.email.delivery.count",
        event_name: [:swoosh, :deliver, :stop],
        measurement: :duration,
        tags: [:outcome],
        tag_values: &email_outcome/1,
        description: "Email deliveries attempted, by outcome"
      ),
      counter("fountain.email.delivery.exception",
        event_name: [:swoosh, :deliver, :exception],
        measurement: :duration,
        description: "Email deliveries that raised"
      ),
      sum("fountain.reaper.run.released",
        event_name: [:fountain, :reaper, :run],
        measurement: :released,
        description: "Sprites released by SandboxReaper runs"
      ),
      sum("fountain.reaper.run.parked",
        event_name: [:fountain, :reaper, :run],
        measurement: :parked,
        description: "Idle server-less sandboxes parked to suspended by SandboxReaper runs"
      ),
      sum("fountain.reaper.run.expired",
        event_name: [:fountain, :reaper, :run],
        measurement: :expired,
        description: "Sandbox rows expired by SandboxReaper runs"
      ),
      # Untracked is a LEVEL, not a delta: every reaper run re-measures the
      # full set of sprites alive at sprites.dev with no sandbox row. As a
      # `sum` it accumulated each hourly observation — a steady 102 leaked
      # sprites read as 2,448 after a day and climbed forever (#405). As a
      # `last_value` the exported gauge is the number of sprites currently
      # leaking money, and it falls when they are cleaned up.
      # released/expired above stay `sum`: those are per-run deltas.
      last_value("fountain.reaper.untracked.count",
        event_name: [:fountain, :reaper, :untracked],
        measurement: :count,
        description: "Untracked sprites currently running with no live sandbox row"
      ),
      # The rehydrator sweep runs once per boot in an unsupervised Task; a
      # crash reaches Sentry via the LoggerHandler, but a sweep that is
      # SKIPPED (leader election) or finds work and starts nothing was
      # invisible — and conversations not resumed after a deploy are exactly
      # what it exists to prevent. last_value: one observation per boot.
      # `:telemetry.span/3` carries the sweep's `{result, extra}` map as stop
      # METADATA, not measurements — hence the measurement functions.
      last_value("fountain.rehydrate.stop.candidates",
        event_name: [:fountain, :rehydrate, :stop],
        measurement: fn _measurements, metadata -> metadata[:candidates] || 0 end,
        description: "Resumable conversations the last rehydrator sweep found"
      ),
      last_value("fountain.rehydrate.stop.started",
        event_name: [:fountain, :rehydrate, :stop],
        measurement: fn _measurements, metadata -> metadata[:started] || 0 end,
        description: "ConversationServers the last rehydrator sweep started"
      ),

      # ── Cost signals (#405) ───────────────────────────────────────────────
      # Both events fired into nothing before this: the provision watchdog
      # (#329) declaring a provision wedged — which per #394 may also leak a
      # sprite — and the durable-output budget (#331) engaging. The emitters
      # attach conversation_id as metadata; it must never become a tag, or
      # every conversation mints its own time series.
      counter("fountain.provision.deadline_exceeded.count",
        event_name: [:fountain, :provision, :deadline_exceeded],
        description:
          "Provisions force-failed by the watchdog deadline; each may leak a sprite (#394)"
      ),
      counter("fountain.log_output.capped.count",
        event_name: [:fountain, :log_output, :capped],
        description: "Conversations whose durable output hit the byte budget and was dropped"
      ),

      # ── Lifecycle funnel (#282) ───────────────────────────────────────────
      # Gauges polled from Fountain.Funnel.emit_telemetry/0 so Grafana can
      # trend stage counts and conversion over time.
      last_value("fountain.funnel.registered",
        event_name: [:fountain, :funnel],
        measurement: :registered,
        description: "Users registered (all time)"
      ),
      last_value("fountain.funnel.verified",
        event_name: [:fountain, :funnel],
        measurement: :verified,
        description: "Users with a verified email"
      ),
      last_value("fountain.funnel.onboarded",
        event_name: [:fountain, :funnel],
        measurement: :onboarded,
        description: "Users who completed onboarding"
      ),
      last_value("fountain.funnel.activated",
        event_name: [:fountain, :funnel],
        measurement: :activated,
        description: "Users with at least one conversation"
      ),
      last_value("fountain.funnel.funded",
        event_name: [:fountain, :funnel],
        measurement: :funded,
        description: "Users with a positive credit balance"
      ),
      last_value("fountain.funnel.stalled_verified",
        event_name: [:fountain, :funnel],
        measurement: :stalled_verified,
        description: "Verified users who never started a conversation"
      ),

      # ── Ops gauges (#321) ─────────────────────────────────────────────────
      # Polled from Fountain.OpsGauges.emit_telemetry/0; zeros emitted for
      # every known status so the series exist from boot.
      last_value("fountain.conversations.count",
        event_name: [:fountain, :conversations],
        measurement: :count,
        tags: [:status],
        description: "Conversations by status"
      ),
      last_value("fountain.sandboxes.count",
        event_name: [:fountain, :sandboxes],
        measurement: :count,
        tags: [:status],
        description: "Sandbox rows by status"
      ),
      last_value("fountain.sandbox_queue.requests.count",
        event_name: [:fountain, :sandbox_queue, :requests],
        measurement: :count,
        tags: [:status],
        description: "Waiting and claimed sandbox request rows by status"
      ),
      # The live view of what the sandbox providers are charging for. Tagged
      # by provider because a minute on each is bought at a different price;
      # not tagged by tenant, which is a database report, not a series.
      last_value("fountain.sandboxes_by_provider.count",
        event_name: [:fountain, :sandboxes_by_provider],
        measurement: :count,
        tags: [:provider, :status],
        description: "Non-terminal sandbox rows by provider and status"
      ),
      last_value("fountain.oban_queue.depth",
        event_name: [:fountain, :oban_queue],
        measurement: :depth,
        tags: [:queue, :state],
        description: "Oban jobs by queue and state (non-terminal states + discarded)"
      ),

      # ── Oban job outcomes (#321) ──────────────────────────────────────────
      # Oban catches job exceptions internally and reports them only via
      # telemetry, so neither the Sentry LoggerHandler nor any crash report
      # reliably sees a failing RetentionPruner or SandboxReaper. These hang
      # directly off Oban's own events — no poller involved.
      counter("fountain.oban_job.stop.count",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        tags: [:queue, :state],
        tag_values: &oban_job_tags/1,
        description: "Completed Oban job executions by queue and result state"
      ),
      counter("fountain.oban_job.exception.count",
        event_name: [:oban, :job, :exception],
        measurement: :duration,
        tags: [:queue, :worker],
        tag_values: &oban_job_tags/1,
        description: "Oban job executions that raised, by queue and worker"
      ),

      # ── Egress broker (ADR 0019, #1170) ───────────────────────────────────
      # Agent Vault exported no metrics at all: its three alerts read
      # kube-state and a blackbox probe, and all three die with its
      # namespace. These are the replacement, and they are what the
      # home-cloud PrometheusRule reads. Only the native backend emits them,
      # so `absent()` means "this deployment brokers and the listener is
      # gone" rather than "this deployment does not broker".
      last_value("fountain.broker.listener.up",
        event_name: [:fountain, :broker, :listener],
        measurement: :up,
        description: "1 when the native egress proxy is accepting connections on this node"
      ),
      last_value("fountain.broker.sessions.count",
        event_name: [:fountain, :broker, :sessions],
        measurement: :count,
        description: "Live broker_sessions rows (one or more per brokered conversation)"
      ),
      last_value("fountain.broker.ca.expires_in_seconds",
        event_name: [:fountain, :broker, :ca],
        measurement: :expires_in_seconds,
        description: "Seconds until the derived broker root CA expires"
      ),
      # The proxy's own event. A policy regression that starts denying
      # api.anthropic.com looks exactly like a spike in `denied`.
      #
      # `tag_values` is not decoration here. The library's `outcome` answers
      # "did a rule apply", and a matched `:passthrough` rule -- how a host is
      # allowed under `limited` -- applies without attaching anything, so it
      # arrives as `:injected`, identical to a `:bearer` rule
      # (managoat/managoat_broker#27). The series has to mean the same thing
      # the egress row means, which is "was a credential attached".
      counter("fountain.broker.request.count",
        event_name: [:managoat, :broker, :request],
        measurement: :count,
        tags: [:outcome],
        tag_values: &broker_request_tags/1,
        description: "Proxied requests by what the broker did: injected, passthrough or denied"
      ),
      # What the *origin* said, now that the proxy frames responses
      # (managoat_broker 0.3.0, #1501 row 2). This is a different signal from
      # `connect.count` below: that one counts connections that never reached
      # an origin, this one counts origins that answered badly. A vendor
      # outage and a credential that stopped working both look like a 5xx or
      # 4xx share here and like nothing at all there.
      #
      # By class rather than by code: a tag straight off `status` would put
      # every status a sandbox can provoke into the label set, and the
      # question an alert asks is "what share of answers were bad".
      counter("fountain.broker.upstream.count",
        event_name: [:managoat, :broker, :request],
        measurement: :count,
        tags: [:status_class],
        tag_values: &broker_upstream_tags/1,
        description:
          "Proxied requests by upstream status class: 2xx, 3xx, 4xx, 5xx, or none " <>
            "where no answer arrived"
      ),
      # A sandbox presenting a token this node cannot resolve: expired,
      # revoked, or a tenant key that stopped decrypting. A storm of these is
      # a 407 storm, which reads to a sandbox as "the network is broken".
      counter("fountain.broker.session_lookup.count",
        event_name: [:fountain, :broker, :session_lookup],
        measurement: :count,
        tags: [:result],
        description: "Broker session lookups by result: ok, expired, unknown or unreadable"
      ),
      counter("fountain.broker.request_log_dropped.count",
        event_name: [:fountain, :broker, :request_log_dropped],
        measurement: :count,
        description: "Egress log rows dropped because the writer's buffer was full"
      ),
      # The connection-level companion to `request.count`, which only counts
      # requests that got as far as a tunnel. This one fires on every
      # connection the proxy decides about, the `502`s and `407`s included,
      # which is what lets "how much of this broker's egress is failing" be a
      # ratio: a count of failures alone cannot tell a broken broker from a
      # busy one. `managoat_broker` 0.1.2 and later.
      #
      # Since 0.10.0 this counts **origin** connections rather than sandbox
      # ones: a plain-HTTP connection is kept alive and carries several
      # requests, dialing once each. A tunnel is still one of each. Every
      # ratio over this event keeps the numerator and denominator it had, so
      # home-cloud's `FountainBrokerUpstreamFailures` is unaffected; only the
      # absolute rate on the plain path moved (#1501 row 4).
      counter("fountain.broker.connect.count",
        event_name: [:managoat, :broker, :connect],
        measurement: :count,
        tags: [:outcome],
        description:
          "Broker connections by outcome: ok, upstream_failed, denied or unauthenticated"
      ),

      # ── VM ────────────────────────────────────────────────────────────────
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  # Route is unbounded if taken from the raw path (every conversation id would
  # mint a new time series), so use the matched route pattern instead.
  defp http_tags(meta) do
    %{
      route: meta[:route] || "unmatched",
      method: meta[:conn] && meta.conn.method,
      status: meta[:conn] && meta.conn.status
    }
  end

  defp exception_tags(meta) do
    %{route: meta[:route] || "unmatched", kind: meta[:kind]}
  end

  # Worker cardinality is bounded by the workers defined in this repo; the
  # queue set by config. `state` is present on :stop (:success, :failure,
  # :snoozed, …) and absent on :exception, where the worker is the signal.
  defp oban_job_tags(meta) do
    %{
      queue: meta.job.queue,
      worker: meta.job.worker,
      state: Map.get(meta, :state, "exception")
    }
  end

  # `outcome: :injected` with `scheme: :passthrough` is a rule that allowed a
  # host without attaching anything. See the counter above.
  defp broker_request_tags(%{outcome: :injected, scheme: :passthrough} = meta),
    do: %{meta | outcome: :passthrough}

  defp broker_request_tags(meta), do: meta

  # `none` is a request the proxy never got an answer to at all -- an origin
  # that would not connect, a refusal it made itself before dialing, a stream
  # that died before a head arrived. It is deliberately a value rather than an
  # absent series, so a ratio can exclude it by name.
  defp broker_upstream_tags(meta) do
    Map.put(meta, :status_class, status_class(Map.get(meta, :status)))
  end

  defp status_class(status) when is_integer(status) and status in 100..599,
    do: "#{div(status, 100)}xx"

  defp status_class(_status), do: "none"

  # Swoosh reports a delivery failure as an `:error` key in the stop event's
  # metadata rather than as a separate event, so the outcome has to be derived
  # (#1169). Two label values only — the error term itself is unbounded and
  # would be a cardinality incident as a label.
  defp email_outcome(meta) do
    %{outcome: if(Map.get(meta, :error), do: "error", else: "ok")}
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("fountain.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("fountain.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("fountain.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("fountain.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("fountain.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  # Funnel stage gauges (#282) and ops gauges (#321). Full-table passes
  # every tick — cheap at current scale. Off in test: the poller's Repo
  # calls would race the SQL Sandbox's connection ownership (the modules
  # are exercised directly by tests instead).
  #
  # Public (with the flag as an argument) so telemetry_test can assert the
  # poller wiring: every MFA here must exist, or telemetry_poller crashes at
  # boot in the only environment where the list is non-empty — production.
  @doc false
  def periodic_measurements(
        enabled? \\ Application.get_env(:fountain, :funnel_poller_enabled, true)
      )

  def periodic_measurements(true) do
    [
      {Fountain.Funnel, :emit_telemetry, []},
      {Fountain.OpsGauges, :emit_telemetry, []},
      {Fountain.Broker.Native, :emit_telemetry, []}
    ]
  end

  def periodic_measurements(false), do: []
end
