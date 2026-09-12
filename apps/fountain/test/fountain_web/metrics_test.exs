defmodule FountainWeb.MetricsTest do
  @moduledoc """
  Cover for the Prometheus scrape surface.

  Two things worth pinning. The reporter rejects `summary/2`, which every metric
  in `metrics/0` uses, so `prometheus_metrics/0` has to stay a separate list —
  wiring the wrong one up raises at boot, in production, after a deploy.

  And route tags must come from the matched route pattern rather than the
  request path, or every conversation id mints a new time series and the
  cardinality quietly eats Prometheus.
  """

  use FountainWeb.ConnCase, async: false

  alias FountainWeb.MetricsPlug
  # Aliased to avoid shadowing Telemetry.Metrics.* struct names below.
  alias FountainWeb.Telemetry, as: AppTelemetry

  defp scrape do
    conn = MetricsPlug.call(Plug.Test.conn(:get, "/metrics"), [])
    {conn.status, conn.resp_body}
  end

  describe "MetricsPlug" do
    test "serves the scrape payload on /metrics" do
      {status, body} = scrape()

      assert status == 200
      assert is_binary(body)
    end

    test "answers /health without a full scrape" do
      conn = MetricsPlug.call(Plug.Test.conn(:get, "/health"), [])

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    test "404s anything else, so the port exposes nothing incidental" do
      conn = MetricsPlug.call(Plug.Test.conn(:get, "/"), [])
      assert conn.status == 404

      conn = MetricsPlug.call(Plug.Test.conn(:get, "/api/agents"), [])
      assert conn.status == 404
    end
  end

  describe "prometheus_metrics/0" do
    test "uses no summary metrics — the reporter cannot represent them" do
      for metric <- AppTelemetry.prometheus_metrics() do
        refute metric.__struct__ == Telemetry.Metrics.Summary,
               "#{inspect(metric.name)} is a summary; " <>
                 "TelemetryMetricsPrometheus.Core raises on those at boot"
      end
    end

    test "every metric is a type the reporter implements" do
      allowed = [
        Telemetry.Metrics.Counter,
        Telemetry.Metrics.Distribution,
        Telemetry.Metrics.LastValue,
        Telemetry.Metrics.Sum
      ]

      for metric <- AppTelemetry.prometheus_metrics() do
        assert metric.__struct__ in allowed,
               "#{inspect(metric.name)} is #{inspect(metric.__struct__)}"
      end
    end

    test "covers the signals an operator needs at 3am" do
      names = Enum.map(AppTelemetry.prometheus_metrics(), & &1.name)

      # Request rate/latency/errors, DB pool saturation, and the domain events
      # that cost money.
      assert [:phoenix, :router_dispatch, :stop, :duration] in names
      assert [:phoenix, :router_dispatch, :exception, :count] in names
      assert [:fountain, :repo, :query, :queue_time] in names
      assert [:fountain, :stage, :count] in names
      assert [:fountain, :fresh_provision, :stop, :duration] in names
    end

    test "reaper untracked is a last_value; released/expired stay sums (#405)" do
      # Untracked is a LEVEL — the current count of leaked sprites, re-measured
      # every reaper run. Declared as a `sum` it accumulated each hourly
      # observation: a steady 102 read as 2,448 after a day, uninterpretable
      # by any dashboard or alert.
      by_name = Map.new(AppTelemetry.prometheus_metrics(), &{&1.name, &1})

      untracked = by_name[[:fountain, :reaper, :untracked, :count]]
      assert untracked, "fountain.reaper.untracked.count is no longer declared"

      assert untracked.__struct__ == Telemetry.Metrics.LastValue,
             "untracked is a level, not a delta; as #{inspect(untracked.__struct__)} " <>
               "it accumulates forever instead of tracking the current leak count"

      # released/parked/expired are per-run deltas — those are correct as sums.
      for measurement <- [:released, :parked, :expired] do
        metric = by_name[[:fountain, :reaper, :run, measurement]]
        assert metric, "fountain.reaper.run.#{measurement} is no longer declared"
        assert metric.__struct__ == Telemetry.Metrics.Sum
      end
    end

    test "every provisioning sub-step has a duration histogram (#537)" do
      # fresh_provision/reattach say provisioning got slower; these say which
      # step did. Before #537 the events fired into nothing but the JSON log,
      # so the only way to attribute a regression was grepping log lines.
      names = Enum.map(AppTelemetry.prometheus_metrics(), & &1.name)

      for span <- [
            [:fountain, :setup_script, :stop, :duration],
            [:fountain, :packages, :stop, :duration],
            [:fountain, :network_policy, :stop, :duration],
            [:fountain, :clone_repositories, :stop, :duration],
            [:fountain, :checkpoint, :create, :stop, :duration],
            [:fountain, :checkpoint, :restore, :stop, :duration]
          ] do
        assert span in names,
               "#{Enum.join(span, ".")} is no longer exported — the span still " <>
                 "fires, but the regression it would explain is invisible again"
      end
    end

    test "provisioning histograms carry no id tags — cardinality (#537)" do
      # Their span metadata holds conv_id / env_id / checkpoint_id. Any of
      # those promoted to a tag mints a time series per conversation.
      for metric <- AppTelemetry.prometheus_metrics(),
          metric.event_name in [
            [:fountain, :setup_script, :stop],
            [:fountain, :packages, :stop],
            [:fountain, :network_policy, :stop],
            [:fountain, :clone_repositories, :stop],
            [:fountain, :checkpoint, :create, :stop],
            [:fountain, :checkpoint, :restore, :stop]
          ] do
        assert metric.tags == [],
               "#{inspect(metric.name)} tags on #{inspect(metric.tags)}"
      end
    end

    test "every subscribed fountain event has a live producer" do
      # The class of bug behind #310: metrics subscribed to event names that
      # nothing emits, passing every name-list assertion while the scrape
      # stays empty forever. Pin each custom event to the code that fires it.
      emitted = [
        # Conversations.publish_stage/4
        [:fountain, :stage],
        # Fountain.Telemetry.span/3 callers
        [:fountain, :fresh_provision, :stop],
        [:fountain, :reattach, :stop],
        # The provisioning sub-steps those two are made of (#537):
        # Conversations.Provisioning (run_setup_script/4 moved there in #1372)
        [:fountain, :setup_script, :stop],
        [:fountain, :packages, :stop],
        [:fountain, :network_policy, :stop],
        [:fountain, :clone_repositories, :stop],
        [:fountain, :checkpoint, :create, :stop],
        [:fountain, :checkpoint, :restore, :stop],
        # Rehydrator.sweep/0 wraps its post-boot sweep in this span; the
        # candidates/started numbers ride the stop event's METADATA (a
        # 2-tuple span return), which is why the metrics use measurement
        # functions.
        [:fountain, :rehydrate, :stop],
        # ConversationServer's terminal turn paths (#536) and its stdout
        # handler (#535) — both exercised by
        # conversation_server_turn_metrics_test.exs against a real server
        [:fountain, :turn, :completed],
        [:fountain, :turn, :first_output],
        # :telemetry.execute call sites
        [:fountain, :sandbox, :reclaimed],
        [:fountain, :sandbox, :suspended],
        [:fountain, :reaper, :run],
        [:fountain, :reaper, :untracked],
        # SandboxQueue emits depth after every mutation and completion at each
        # terminal transition; OpsGauges emits the live row counts (#1033).
        [:fountain, :sandbox_queue, :tenant_depth],
        [:fountain, :sandbox_queue, :completed],
        [:fountain, :sandbox_queue, :requests],
        # Audit.record_admin/1 rejection path (#451) — exercised by
        # Fountain.AuditTest's rejected-write telemetry test
        [:fountain, :audit, :admin_record_rejected],
        # RefreshLock.attempt/4 contention path — exercised by
        # Fountain.ChatGPTRefreshCoordinationTest's contender tests
        [:fountain, :chatgpt, :refresh_lock, :contention],
        # Billing.record_usage/5 swallow path (#503) — exercised by
        # Fountain.UsageMeteringTest's dropped-usage telemetry test
        [:fountain, :usage, :dropped],
        # ConversationServer: provision watchdog (#329) and durable-output
        # budget (#331) — the two cost signals #405 gave subscribers
        [:fountain, :provision, :deadline_exceeded],
        [:fountain, :log_output, :capped],
        # Fountain.OpsGauges.emit_telemetry/0 (#321) — exercised directly by
        # Fountain.OpsGaugesTest since the poller is off in test
        [:fountain, :conversations],
        [:fountain, :sandboxes],
        [:fountain, :sandboxes_by_provider],
        [:fountain, :oban_queue],
        # Fountain.Broker.Native.emit_telemetry/0 (#1170) — exercised
        # directly by Fountain.BrokerNativeTest, since the poller is off in
        # test and these are emitted only on the native backend
        [:fountain, :broker, :listener],
        [:fountain, :broker, :sessions],
        [:fountain, :broker, :ca],
        # Fountain.Broker.Native.Sessions.lookup/1, on every proxy connection
        [:fountain, :broker, :session_lookup],
        # Fountain.Broker.Native.RequestLog, when its buffer saturates
        [:fountain, :broker, :request_log_dropped],
        # Emitted by the proxy itself (Managoat.Broker.Proxy.log_request/4),
        # which Fountain.Broker.Native.handle_request/4 also writes rows from
        [:managoat, :broker, :request],
        # Also the proxy's own (Managoat.Broker.Proxy.connect_event/4, since
        # managoat_broker 0.1.2): once per connection rather than per request
        [:managoat, :broker, :connect],
        # Credits and billing (#1169). The two are deliberately different
        # producers: `worker.run` is Fountain.Credits.Telemetry.emit_run/2,
        # called from each credit worker's perform/1, and answers "did it
        # run"; `posted` is Fountain.Credits.post/4 at the ledger write, and
        # answers "did money move". Both are exercised by
        # Fountain.CreditsTelemetryTest.
        [:fountain, :credits, :worker, :run],
        [:fountain, :credits, :posted],
        # FountainWeb.StripeWebhookController, on every rejected or failed
        # delivery — exercised by its controller test.
        [:fountain, :stripe_webhook, :failure],
        # Swoosh's own span around Mailer.deliver/1, which is why the email
        # metrics needed no call-site change across the fourteen deliver
        # sites. A failure is an `:error` key in the stop event's metadata,
        # not a separate event, hence the derived `outcome` tag.
        [:swoosh, :deliver, :stop],
        [:swoosh, :deliver, :exception],
        # Emitted by Oban itself around every job execution
        [:oban, :job, :stop],
        [:oban, :job, :exception],
        # Library-emitted
        [:phoenix, :router_dispatch, :stop],
        [:phoenix, :router_dispatch, :exception],
        [:fountain, :repo, :query],
        [:fountain, :funnel],
        [:vm, :memory],
        [:vm, :total_run_queue_lengths]
      ]

      for metric <- AppTelemetry.prometheus_metrics() do
        assert metric.event_name in emitted,
               "#{inspect(metric.name)} subscribes to #{inspect(metric.event_name)}, " <>
                 "which no known code path emits — this is how #310 happened"
      end
    end
  end

  describe "end to end" do
    test "a real request lands in the scrape output", %{conn: conn} do
      user = insert_verified_user()
      {_rec, key} = insert_api_key(user)

      conn |> authed_with_key(key) |> get("/api/agents") |> json_response(200)

      # The reporter aggregates synchronously on the telemetry event, but give
      # the handler a moment before scraping.
      Process.sleep(50)
      {200, body} = scrape()

      assert body =~ "phoenix_router_dispatch_stop_duration"
    end

    test "a stage event lands in the scrape with stage and status labels" do
      # The subscription side of the stage counter. The producer side —
      # ConversationServer actually publishing these stages — is asserted in
      # conversation_server_test.exs against a real provision.
      Fountain.Telemetry.event(
        [:stage],
        %{stage: "provision", status: "failed", conv_id: Ecto.UUID.generate()},
        %{count: 1}
      )

      Process.sleep(50)
      {200, body} = scrape()

      assert Regex.match?(
               ~r/fountain_stage_count\{[^}]*stage="provision"[^}]*status="failed"[^}]*\}/,
               body
             )

      # conv_id is metadata, never a label — one series per conversation
      # would eat Prometheus.
      refute body =~ "conv_id="
    end

    test "a proxied request lands in the scrape by outcome and by upstream status class" do
      # Two series off one event (#1501 row 2). `request_count` answers "what
      # did the broker do", `upstream_count` "what did the origin say" -- the
      # second is only possible now that the proxy frames responses.
      for {scheme, status} <- [{:bearer, 200}, {:passthrough, 503}, {nil, nil}] do
        :telemetry.execute([:managoat, :broker, :request], %{count: 1, duration: 0}, %{
          method: "GET",
          host: "api.example.com",
          path: "/v1/x",
          outcome: if(scheme, do: :injected, else: :denied),
          rule: scheme && "a-rule",
          scheme: scheme,
          status: status,
          error: nil,
          meta: %{"conversation_id" => Ecto.UUID.generate()}
        })
      end

      Process.sleep(50)
      {200, body} = scrape()

      for status_class <- ~w(2xx 5xx none) do
        assert Regex.match?(
                 ~r/fountain_broker_upstream_count\{[^}]*status_class="#{status_class}"[^}]*\}/,
                 body
               ),
               "status_class=#{status_class} is missing from the scrape"
      end

      # A matched `:passthrough` rule reaches the event as `outcome: :injected`
      # -- from the proxy's side a rule applied. The series has to mean "was a
      # credential attached", or an allowlisted host reads as a credentialed
      # one (managoat/managoat_broker#27).
      for outcome <- ~w(injected passthrough denied) do
        assert Regex.match?(
                 ~r/fountain_broker_request_count\{[^}]*outcome="#{outcome}"[^}]*\}/,
                 body
               ),
               "outcome=#{outcome} is missing from the scrape"
      end

      # The status itself is metadata, never a label on these series: one
      # series per status a sandbox can provoke is what the class exists to
      # avoid. Scoped to the broker metrics on purpose -- the scrape is the
      # whole node, and other producers label by status legitimately.
      refute Regex.match?(~r/fountain_broker_[a-z_]*\{[^}]*[^_]status="/, body)
      refute body =~ ~s(host="api.example.com")
    end

    test "broker connect outcomes land in the scrape, so the failure ratio has both halves (#1170)" do
      # FountainBrokerUpstreamFailures divides upstream_failed by the
      # connections that dialled out at all. Both label values have to reach
      # Prometheus for that to be a ratio rather than a bare count.
      for outcome <- [:ok, :upstream_failed, :denied, :unauthenticated] do
        :telemetry.execute([:managoat, :broker, :connect], %{count: 1}, %{
          host: "api.example.com",
          port: 443,
          outcome: outcome,
          meta: %{"conversation_id" => Ecto.UUID.generate()}
        })
      end

      Process.sleep(50)
      {200, body} = scrape()

      for outcome <- ~w(ok upstream_failed denied unauthenticated) do
        assert Regex.match?(
                 ~r/fountain_broker_connect_count\{[^}]*outcome="#{outcome}"[^}]*\}/,
                 body
               ),
               "outcome=#{outcome} is missing from the scrape"
      end

      # host and conversation_id are metadata, never labels: one series per
      # origin a sandbox names is unbounded, and one per conversation worse.
      refute body =~ ~s(host="api.example.com")
      refute body =~ "conversation_id="
    end

    test "ops gauges and Oban events land in the scrape (#321)" do
      :telemetry.execute([:fountain, :conversations], %{count: 3}, %{status: "idle"})

      :telemetry.execute([:fountain, :oban_queue], %{depth: 2}, %{
        queue: "maintenance",
        state: "available"
      })

      job = %Oban.Job{queue: "maintenance", worker: "Fountain.Workers.SandboxReaper"}
      :telemetry.execute([:oban, :job, :stop], %{duration: 1_000}, %{job: job, state: :success})

      :telemetry.execute([:oban, :job, :exception], %{duration: 1_000}, %{
        job: job,
        kind: :error,
        reason: %RuntimeError{message: "boom"},
        stacktrace: []
      })

      Process.sleep(50)
      {200, body} = scrape()

      assert Regex.match?(~r/fountain_conversations_count\{[^}]*status="idle"[^}]*\} 3/, body)

      assert Regex.match?(
               ~r/fountain_oban_queue_depth\{[^}]*queue="maintenance"[^}]*state="available"[^}]*\} 2/,
               body
             )

      assert Regex.match?(
               ~r/fountain_oban_job_stop_count\{[^}]*queue="maintenance"[^}]*state="success"[^}]*\}/,
               body
             )

      assert Regex.match?(
               ~r/fountain_oban_job_exception_count\{[^}]*worker="Fountain.Workers.SandboxReaper"[^}]*\}/,
               body
             )
    end

    test "untracked scrapes as a gauge that falls when the level drops (#405)" do
      # The sum-vs-level bug: as a `sum`, 102 followed by 3 scrapes as 105 and
      # climbs forever; as a `last_value` it scrapes as the current level.
      # Values are distinctive so a concurrent reaper test (which emits 2)
      # is distinguishable in a failure message.
      :telemetry.execute([:fountain, :reaper, :untracked], %{count: 102}, %{})
      Process.sleep(50)
      {200, body} = scrape()

      assert body =~ ~r/^fountain_reaper_untracked_count 102$/m
      assert body =~ ~r/^# TYPE fountain_reaper_untracked_count gauge$/m

      :telemetry.execute([:fountain, :reaper, :untracked], %{count: 3}, %{})
      Process.sleep(50)
      {200, body} = scrape()

      assert body =~ ~r/^fountain_reaper_untracked_count 3$/m
      refute body =~ ~r/^fountain_reaper_untracked_count 105$/m
    end

    test "cost-signal counters increment on their events (#405)" do
      deadline = ~r/^fountain_provision_deadline_exceeded_count (\d+)$/m
      capped = ~r/^fountain_log_output_capped_count (\d+)$/m

      emit_both = fn ->
        # Measurements/metadata mirror the emitters in conversation_server.ex.
        :telemetry.execute([:fountain, :provision, :deadline_exceeded], %{count: 1}, %{
          conversation_id: Ecto.UUID.generate()
        })

        :telemetry.execute([:fountain, :log_output, :capped], %{count: 1}, %{
          conversation_id: Ecto.UUID.generate()
        })
      end

      emit_both.()
      Process.sleep(50)
      {200, body} = scrape()

      assert [_, deadline_before] = Regex.run(deadline, body)
      assert [_, capped_before] = Regex.run(capped, body)

      emit_both.()
      Process.sleep(50)
      {200, body} = scrape()

      assert [_, deadline_after] = Regex.run(deadline, body)
      assert [_, capped_after] = Regex.run(capped, body)

      assert String.to_integer(deadline_after) == String.to_integer(deadline_before) + 1
      assert String.to_integer(capped_after) == String.to_integer(capped_before) + 1

      # conversation_id is metadata, never a label — one series per
      # conversation would eat Prometheus.
      refute body =~ "conversation_id="
    end

    test "a provisioning sub-step span lands in the scrape (#537)" do
      # Driven through the real Fountain.Telemetry.span/3 rather than a raw
      # :telemetry.execute, so the event name and the `duration` measurement
      # are the ones the provisioning code actually produces. A series exists
      # in the scrape only once its event has fired, so each name asserted
      # below is emitted here.
      conv_id = Ecto.UUID.generate()

      Fountain.Telemetry.span([:packages], %{conv_id: conv_id, commands: 2}, fn ->
        {:ok, %{outcome: :ok}}
      end)

      Fountain.Telemetry.span([:checkpoint, :create], %{env_id: Ecto.UUID.generate()}, fn ->
        {:ok, %{outcome: :ok}}
      end)

      Fountain.Telemetry.span([:checkpoint, :restore], %{checkpoint_id: "ckpt_1"}, fn ->
        {:ok, %{outcome: :ok}}
      end)

      Process.sleep(50)
      {200, body} = scrape()

      assert body =~ "fountain_packages_stop_duration_bucket"
      assert body =~ "fountain_checkpoint_create_stop_duration_bucket"
      assert body =~ "fountain_checkpoint_restore_stop_duration_bucket"

      # conv_id / checkpoint_id are span metadata, never labels.
      refute body =~ conv_id
      refute body =~ "checkpoint_id="
    end

    test "turn duration scrapes with runtime and status labels (#536)" do
      # The subscription side. The producer side — ConversationServer emitting
      # this on every terminal turn path — is asserted in
      # conversation_server_turn_metrics_test.exs against a real server.
      # The reporter is global to the VM and the ConversationServer tests feed
      # the same histogram with runtime="claude". "opencode" is emitted by
      # nothing else, so the bucket counts below are this test's alone.
      Fountain.Telemetry.event(
        [:turn, :completed],
        %{
          runtime: "opencode",
          status: "completed",
          provider: "runner",
          conv_id: Ecto.UUID.generate()
        },
        %{duration_ms: 42_000}
      )

      Process.sleep(50)
      {200, body} = scrape()

      series =
        ~s(fountain_turn_completed_duration_ms_bucket{provider="runner",runtime="opencode",status="completed")

      # 42s lands above the 30s boundary and below 60s. A duration handed over
      # in seconds or in native units lands in a different bucket entirely.
      assert body =~ ~s(#{series},le="60000"} 1)
      assert body =~ ~s(#{series},le="30000"} 0)

      refute body =~ "conv_id="
    end

    test "time to first token scrapes tagged by runtime (#535)" do
      # A synthetic runtime, not a real one. The reporter is global and
      # cumulative, so this asserts an exact bucket count only as long as
      # nothing else in the suite emits the same tag — and "gemini" stopped
      # being safe the moment the ACP conversion grew gemini ConversationServer
      # tests, which feed first-output telemetry of their own. A tag no runtime
      # can ever be named keeps the exact-count assertions meaningful.
      Fountain.Telemetry.event(
        [:turn, :first_output],
        %{runtime: "probe-runtime", provider: "runner", conv_id: Ecto.UUID.generate()},
        %{elapsed_ms: 1_500}
      )

      Process.sleep(50)
      {200, body} = scrape()

      series =
        ~s(fountain_turn_first_output_elapsed_ms_bucket{provider="runner",runtime="probe-runtime")

      # 1.5s is above the 1s boundary and below 2.5s.
      assert body =~ ~s(#{series},le="2500"} 1)
      assert body =~ ~s(#{series},le="1000"} 0)

      # No status tag here: a turn reports first output once, before any
      # outcome is known.
      refute body =~
               ~s(fountain_turn_first_output_elapsed_ms_bucket{runtime="probe-runtime",status)

      refute body =~ "conv_id="
    end

    test "route tags are the matched pattern, not the raw path", %{conn: conn} do
      user = insert_verified_user()
      {_rec, key} = insert_api_key(user)
      conv = insert_conversation(user_id: user.id)

      conn |> authed_with_key(key) |> get("/api/conversations/#{conv.id}")

      Process.sleep(50)
      {200, body} = scrape()

      # The conversation id must not appear as a label value; if it does, every
      # conversation is its own time series.
      refute body =~ conv.id
    end
  end
end
