defmodule Fountain.FeatureFlagsTest do
  # Mutates global app env (the PostHog key, the overrides), so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fountain.FeatureFlags

  @user_id "11111111-1111-1111-1111-111111111111"

  # A neutral flag key, not one of `@flags`. `enabled?/2` takes the PostHog
  # string directly, so this suite can exercise evaluation, caching and the
  # capture behaviour without pinning itself to whichever real flag happens
  # to exist — which is what tied it to the retired `openai_compat` (#2252).
  @flag "test_flag"

  setup do
    previous = %{
      key: Application.get_env(:fountain, :posthog_project_api_key),
      overrides: Application.get_env(:fountain, :feature_flag_overrides)
    }

    FeatureFlags.reset()

    # A flag read now also captures `$feature_flag_called`. Swallow it here so
    # these tests stay about flag evaluation; `analytics_test.exs` and the
    # block at the bottom of this file own the capture behaviour.
    Req.Test.stub(Fountain.Analytics, fn conn -> Req.Test.json(conn, %{"status" => 1}) end)

    on_exit(fn ->
      restore(:posthog_project_api_key, previous.key)
      restore(:feature_flag_overrides, previous.overrides)
      FeatureFlags.reset()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp posthog_on, do: Application.put_env(:fountain, :posthog_project_api_key, "phc_test")
  defp posthog_off, do: Application.delete_env(:fountain, :posthog_project_api_key)

  defp stub_flags(flags) do
    Req.Test.stub(FeatureFlags, fn conn ->
      Req.Test.json(conn, %{"flags" => Map.new(flags, fn {k, v} -> {k, %{"enabled" => v}} end)})
    end)
  end

  defp stub_down do
    Req.Test.stub(FeatureFlags, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
  end

  describe "without PostHog" do
    test "every flag reads off" do
      posthog_off()
      refute FeatureFlags.enabled?(@flag, @user_id)
    end

    test "a static override turns a flag on for everyone" do
      posthog_off()
      Application.put_env(:fountain, :feature_flag_overrides, %{@flag => true})
      assert FeatureFlags.enabled?(@flag, @user_id)
      assert FeatureFlags.enabled?(@flag, %{id: @user_id})
      # An override applies even with no user to ask about.
      assert FeatureFlags.enabled?(@flag, nil)
    end

    test "an unknown flag atom is a KeyError, not a silent off" do
      assert_raise KeyError, fn -> FeatureFlags.enabled?(:no_such_flag, @user_id) end
    end

    # A flag over a shipped feature reads on where there is nobody to ask, or
    # a self-host loses the feature on the upgrade that added the flag (#1693).
    test "a flag that gates a shipped feature reads on" do
      posthog_off()
      assert FeatureFlags.enabled?(:connections, @user_id)
      assert FeatureFlags.enabled?(:connections, nil)
      refute FeatureFlags.enabled?(@flag, @user_id)
    end

    test "a static override still decides, in both directions" do
      posthog_off()
      Application.put_env(:fountain, :feature_flag_overrides, %{"connections" => false})
      refute FeatureFlags.enabled?(:connections, @user_id)
    end
  end

  describe "with PostHog" do
    setup do
      posthog_on()
      :ok
    end

    test "reads the flag for the user" do
      stub_flags(%{@flag => true})
      assert FeatureFlags.enabled?(@flag, @user_id)

      stub_flags(%{@flag => false})
      FeatureFlags.reset()
      refute FeatureFlags.enabled?(@flag, @user_id)
    end

    test "a flag PostHog does not mention is off" do
      stub_flags(%{"something_else" => true})
      refute FeatureFlags.enabled?(@flag, @user_id)
    end

    # The default is for a deployment with no flag service. Where there is one,
    # its answer decides, including for a flag it does not mention.
    test "PostHog's answer beats the no-PostHog default" do
      stub_flags(%{"connections" => false})
      refute FeatureFlags.enabled?(:connections, @user_id)

      stub_flags(%{"something_else" => true})
      FeatureFlags.reset()
      refute FeatureFlags.enabled?(:connections, @user_id)
    end

    test "also reads the older /decide shape" do
      Req.Test.stub(FeatureFlags, fn conn ->
        Req.Test.json(conn, %{"featureFlags" => %{@flag => true}})
      end)

      assert FeatureFlags.enabled?(@flag, @user_id)
    end

    test "a static override wins over PostHog" do
      stub_flags(%{@flag => true})
      Application.put_env(:fountain, :feature_flag_overrides, %{@flag => false})
      refute FeatureFlags.enabled?(@flag, @user_id)
    end

    test "caches the answer: a second call does not hit PostHog" do
      test = self()

      Req.Test.stub(FeatureFlags, fn conn ->
        send(test, :posthog_called)
        Req.Test.json(conn, %{"flags" => %{@flag => %{"enabled" => true}}})
      end)

      assert FeatureFlags.enabled?(@flag, @user_id)
      assert_received :posthog_called
      assert FeatureFlags.enabled?(@flag, @user_id)
      refute_received :posthog_called
    end

    test "no user to ask about reads off without a call" do
      Req.Test.stub(FeatureFlags, fn _conn -> flunk("PostHog should not be called") end)
      refute FeatureFlags.enabled?(@flag, nil)
    end
  end

  describe "when PostHog is down" do
    setup do
      posthog_on()
      :ok
    end

    test "with no cached answer every flag reads off — never on" do
      stub_down()
      refute FeatureFlags.enabled?(@flag, @user_id)
    end

    test "a 5xx is an outage too" do
      Req.Test.stub(FeatureFlags, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      refute FeatureFlags.enabled?(@flag, @user_id)
    end

    test "the last answer it gave is kept — on stays on" do
      stub_flags(%{@flag => true})
      assert FeatureFlags.enabled?(@flag, @user_id)

      # Expire the cache entry, then take PostHog down.
      age_cache(@user_id)
      stub_down()
      assert FeatureFlags.enabled?(@flag, @user_id)
    end

    test "the last answer it gave is kept — off stays off" do
      stub_flags(%{@flag => false})
      refute FeatureFlags.enabled?(@flag, @user_id)

      age_cache(@user_id)
      stub_down()
      refute FeatureFlags.enabled?(@flag, @user_id)
    end
  end

  # A flag in `@on_without_posthog` gates a feature that is built. PostHog
  # omitting it from an answer is a mistake in the project — not a decision to
  # turn the feature off — and before #2347 nothing said so.
  describe "a built feature's flag that PostHog never mentions" do
    setup do
      posthog_on()
      :ok
    end

    test "logs an error naming the flag, and still reads off" do
      stub_flags(%{"something_else" => true})

      log = capture_log(fn -> refute FeatureFlags.enabled?(:connections, @user_id) end)

      assert log =~ "connections"
      assert log =~ "does not mention it"
      assert log =~ "FEATURE_FLAGS_ON=connections"
    end

    # The whole point: "off because we asked and were told no" is a decision,
    # and saying nothing is what a decision deserves.
    test "an answer of off is silent" do
      stub_flags(%{"connections" => false})

      log = capture_log(fn -> refute FeatureFlags.enabled?(:connections, @user_id) end)

      refute log =~ "does not mention it"
    end

    test "an answer of on is silent" do
      stub_flags(%{"connections" => true})

      log = capture_log(fn -> assert FeatureFlags.enabled?(:connections, @user_id) end)

      refute log =~ "does not mention it"
    end

    # Only the flags over built features. An unfinished one is *expected* to
    # be missing until its rollout starts.
    test "a flag over an unfinished feature says nothing when it is missing" do
      stub_flags(%{"something_else" => true})

      log = capture_log(fn -> refute FeatureFlags.enabled?(@flag, @user_id) end)

      refute log =~ "does not mention it"
    end

    test "says it once per cache window, not once per read" do
      stub_flags(%{"something_else" => true})

      log = capture_log(fn -> refute FeatureFlags.enabled?(:connections, @user_id) end)
      assert log =~ "does not mention it"

      # Expire the person's cached answer so the next read is a fresh call and
      # reaches the check again. The warning is still inside its own window.
      age_cache(@user_id)

      log = capture_log(fn -> refute FeatureFlags.enabled?(:connections, @user_id) end)
      refute log =~ "does not mention it"
    end

    # An unreachable PostHog is not evidence that a flag is undefined, and
    # saying so would point at the wrong thing during an outage.
    test "an outage with nothing cached is not reported as a missing flag" do
      stub_down()

      log = capture_log(fn -> refute FeatureFlags.enabled?(:connections, @user_id) end)

      assert log =~ "lookup failed"
      refute log =~ "does not mention it"
    end

    # A stale answer is still an answer PostHog gave about this person, so a
    # key absent from it is absent on purpose.
    test "a stale cached answer still reports a flag missing from it" do
      stub_flags(%{"something_else" => true})
      capture_log(fn -> refute FeatureFlags.enabled?(:connections, @user_id) end)

      # Past the warning's own window as well as the cache's, with PostHog
      # down so the stale answer is what gets read.
      age_cache(@user_id)
      age_warning(:connections)
      stub_down()

      log = capture_log(fn -> refute FeatureFlags.enabled?(:connections, @user_id) end)

      assert log =~ "does not mention it"
    end
  end

  describe "what analytics is told" do
    setup do
      stub_flags(%{@flag => true})
      test = self()

      Req.Test.stub(Fountain.Analytics, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:posthog, Jason.decode!(body)})
        Req.Test.json(conn, %{"status" => 1})
      end)

      :ok
    end

    test "reading a flag captures $feature_flag_called with the answer" do
      posthog_on()
      assert FeatureFlags.enabled?(@flag, @user_id)

      assert_receive {:posthog, %{"batch" => [event]}}
      assert event["event"] == "$feature_flag_called"
      assert event["distinct_id"] == @user_id
      assert event["properties"]["$feature_flag"] == @flag
      assert event["properties"]["$feature_flag_response"] == true
    end

    test "reading the same flag again inside the cache window says nothing more" do
      posthog_on()
      assert FeatureFlags.enabled?(@flag, @user_id)
      assert_receive {:posthog, _}

      assert FeatureFlags.enabled?(@flag, @user_id)
      refute_receive {:posthog, _}, 50
    end

    test "cached_flags/1 reports what is known without calling PostHog" do
      posthog_on()
      assert FeatureFlags.enabled?(@flag, @user_id)

      Req.Test.stub(FeatureFlags, fn _conn -> flunk("must not call PostHog") end)
      assert FeatureFlags.cached_flags(@user_id) == %{@flag => true}
    end

    test "cached_flags/1 is empty for a person nothing is known about" do
      posthog_on()
      assert FeatureFlags.cached_flags("44444444-4444-4444-4444-444444444444") == %{}
      assert FeatureFlags.cached_flags(nil) == %{}
    end

    test "a static override shows up in cached_flags/1 with no PostHog at all" do
      posthog_off()
      Application.put_env(:fountain, :feature_flag_overrides, %{@flag => true})

      assert FeatureFlags.cached_flags(@user_id) == %{@flag => true}
    end
  end

  # Push the "we already said this" marker into the past so the next missing
  # flag warns again.
  defp age_warning(flag) do
    key = {:undefined, FeatureFlags.key!(flag)}

    :ets.insert(
      FeatureFlags.table(),
      {key, :logged, System.monotonic_time(:millisecond) - 600_000}
    )
  end

  # Push the cached entry's timestamp into the past so the next read refetches.
  defp age_cache(distinct_id) do
    [{^distinct_id, flags, _at}] = :ets.lookup(FeatureFlags.table(), distinct_id)

    :ets.insert(
      FeatureFlags.table(),
      {distinct_id, flags, System.monotonic_time(:millisecond) - 600_000}
    )
  end
end
