defmodule Fountain.FeatureFlagsTest do
  # Mutates global app env (the PostHog key, the overrides), so not async.
  use ExUnit.Case, async: false

  alias Fountain.FeatureFlags

  @user_id "11111111-1111-1111-1111-111111111111"

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
      refute FeatureFlags.enabled?(:openai_compat, @user_id)
    end

    test "a static override turns a flag on for everyone" do
      posthog_off()
      Application.put_env(:fountain, :feature_flag_overrides, %{"openai_compat" => true})
      assert FeatureFlags.enabled?(:openai_compat, @user_id)
      assert FeatureFlags.enabled?(:openai_compat, %{id: @user_id})
      # An override applies even with no user to ask about.
      assert FeatureFlags.enabled?(:openai_compat, nil)
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
      refute FeatureFlags.enabled?(:openai_compat, @user_id)
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
      stub_flags(%{"openai_compat" => true})
      assert FeatureFlags.enabled?(:openai_compat, @user_id)

      stub_flags(%{"openai_compat" => false})
      FeatureFlags.reset()
      refute FeatureFlags.enabled?(:openai_compat, @user_id)
    end

    test "a flag PostHog does not mention is off" do
      stub_flags(%{"something_else" => true})
      refute FeatureFlags.enabled?(:openai_compat, @user_id)
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
        Req.Test.json(conn, %{"featureFlags" => %{"openai_compat" => true}})
      end)

      assert FeatureFlags.enabled?(:openai_compat, @user_id)
    end

    test "a static override wins over PostHog" do
      stub_flags(%{"openai_compat" => true})
      Application.put_env(:fountain, :feature_flag_overrides, %{"openai_compat" => false})
      refute FeatureFlags.enabled?(:openai_compat, @user_id)
    end

    test "caches the answer: a second call does not hit PostHog" do
      test = self()

      Req.Test.stub(FeatureFlags, fn conn ->
        send(test, :posthog_called)
        Req.Test.json(conn, %{"flags" => %{"openai_compat" => %{"enabled" => true}}})
      end)

      assert FeatureFlags.enabled?(:openai_compat, @user_id)
      assert_received :posthog_called
      assert FeatureFlags.enabled?(:openai_compat, @user_id)
      refute_received :posthog_called
    end

    test "no user to ask about reads off without a call" do
      Req.Test.stub(FeatureFlags, fn _conn -> flunk("PostHog should not be called") end)
      refute FeatureFlags.enabled?(:openai_compat, nil)
    end
  end

  describe "when PostHog is down" do
    setup do
      posthog_on()
      :ok
    end

    test "with no cached answer every flag reads off — never on" do
      stub_down()
      refute FeatureFlags.enabled?(:openai_compat, @user_id)
    end

    test "a 5xx is an outage too" do
      Req.Test.stub(FeatureFlags, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      refute FeatureFlags.enabled?(:openai_compat, @user_id)
    end

    test "the last answer it gave is kept — on stays on" do
      stub_flags(%{"openai_compat" => true})
      assert FeatureFlags.enabled?(:openai_compat, @user_id)

      # Expire the cache entry, then take PostHog down.
      age_cache(@user_id)
      stub_down()
      assert FeatureFlags.enabled?(:openai_compat, @user_id)
    end

    test "the last answer it gave is kept — off stays off" do
      stub_flags(%{"openai_compat" => false})
      refute FeatureFlags.enabled?(:openai_compat, @user_id)

      age_cache(@user_id)
      stub_down()
      refute FeatureFlags.enabled?(:openai_compat, @user_id)
    end
  end

  describe "what analytics is told" do
    setup do
      stub_flags(%{"openai_compat" => true})
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
      assert FeatureFlags.enabled?(:openai_compat, @user_id)

      assert_receive {:posthog, %{"batch" => [event]}}
      assert event["event"] == "$feature_flag_called"
      assert event["distinct_id"] == @user_id
      assert event["properties"]["$feature_flag"] == "openai_compat"
      assert event["properties"]["$feature_flag_response"] == true
    end

    test "reading the same flag again inside the cache window says nothing more" do
      posthog_on()
      assert FeatureFlags.enabled?(:openai_compat, @user_id)
      assert_receive {:posthog, _}

      assert FeatureFlags.enabled?(:openai_compat, @user_id)
      refute_receive {:posthog, _}, 50
    end

    test "cached_flags/1 reports what is known without calling PostHog" do
      posthog_on()
      assert FeatureFlags.enabled?(:openai_compat, @user_id)

      Req.Test.stub(FeatureFlags, fn _conn -> flunk("must not call PostHog") end)
      assert FeatureFlags.cached_flags(@user_id) == %{"openai_compat" => true}
    end

    test "cached_flags/1 is empty for a person nothing is known about" do
      posthog_on()
      assert FeatureFlags.cached_flags("44444444-4444-4444-4444-444444444444") == %{}
      assert FeatureFlags.cached_flags(nil) == %{}
    end

    test "a static override shows up in cached_flags/1 with no PostHog at all" do
      posthog_off()
      Application.put_env(:fountain, :feature_flag_overrides, %{"openai_compat" => true})

      assert FeatureFlags.cached_flags(@user_id) == %{"openai_compat" => true}
    end
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
