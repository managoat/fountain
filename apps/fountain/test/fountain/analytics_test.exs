defmodule Fountain.AnalyticsTest do
  # Mutates global app env (the PostHog key, the PII switch), so not async.
  use ExUnit.Case, async: false

  alias Fountain.Analytics
  alias Fountain.Accounts.User

  @user_id "22222222-2222-2222-2222-222222222222"

  setup do
    previous = %{
      key: Application.get_env(:fountain, :posthog_project_api_key),
      enabled: Application.get_env(:fountain, :analytics_enabled),
      pii: Application.get_env(:fountain, :analytics_person_pii),
      overrides: Application.get_env(:fountain, :feature_flag_overrides)
    }

    Fountain.FeatureFlags.reset()

    on_exit(fn ->
      restore(:posthog_project_api_key, previous.key)
      restore(:analytics_enabled, previous.enabled)
      restore(:analytics_person_pii, previous.pii)
      restore(:feature_flag_overrides, previous.overrides)
      Fountain.FeatureFlags.reset()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp posthog_on, do: Application.put_env(:fountain, :posthog_project_api_key, "phc_test")

  defp stub_capture do
    test = self()

    Req.Test.stub(Analytics, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posthog, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"status" => 1})
    end)
  end

  defp user(attrs \\ %{}) do
    Map.merge(
      %User{
        id: @user_id,
        email: "someone@example.com",
        role: "user",
        comped: false,
        credit_balance_cents: 0,
        sandbox_limit_override: nil,
        inserted_at: ~U[2026-01-01 00:00:00Z]
      },
      attrs
    )
  end

  describe "without a project API key" do
    test "capture sends nothing at all" do
      Application.delete_env(:fountain, :posthog_project_api_key)
      Req.Test.stub(Analytics, fn _conn -> flunk("PostHog should not be called") end)

      assert :ok = Analytics.capture("agent.created", @user_id)
      refute Analytics.enabled?()
    end
  end

  describe "POSTHOG_CAPTURE=false" do
    test "leaves flag evaluation configured but stops capture" do
      posthog_on()
      Application.put_env(:fountain, :analytics_enabled, false)
      Req.Test.stub(Analytics, fn _conn -> flunk("PostHog should not be called") end)

      assert :ok = Analytics.capture("agent.created", @user_id)
      refute Analytics.enabled?()
      # The flag half of the same key is unaffected.
      assert Fountain.FeatureFlags.configured?()
    end
  end

  describe "capture/4" do
    setup do
      posthog_on()
      stub_capture()
      :ok
    end

    test "posts one event to the batch endpoint" do
      Analytics.capture("agent.created", @user_id, %{"resource_type" => "agent"})

      assert_receive {:posthog, "/batch/", body}
      assert body["api_key"] == "phc_test"
      assert [event] = body["batch"]
      assert event["event"] == "agent.created"
      assert event["distinct_id"] == @user_id
      assert event["properties"]["resource_type"] == "agent"
    end

    test "stamps the library, the environment and the instance group" do
      Analytics.capture("agent.created", @user_id)

      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      assert event["properties"]["$lib"] == "fountain-elixir"
      assert event["properties"]["environment"] == "test"
      assert event["properties"]["$groups"] == %{"instance" => "test"}
    end

    test "accepts a user struct as the subject" do
      Analytics.capture("agent.created", user())

      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      assert event["distinct_id"] == @user_id
    end

    test "drops an event that names nobody rather than inventing a person" do
      Req.Test.stub(Analytics, fn _conn -> flunk("PostHog should not be called") end)

      assert :ok = Analytics.capture("agent.created", nil)
    end

    test "disables enrichment by default, so PostHog does not geolocate the deployment" do
      # This test used to assert `"$ip" => nil` and describe that as sending no
      # IP. It was asserting the bug: PostHog reads a null or missing `$ip` as
      # "use the address the batch came from" and geolocates the sending pod,
      # which put every pageview in the project in one city. `$geoip_disable`
      # is the documented way to say "unknown". See ADR 0028.
      Analytics.capture("agent.created", @user_id)

      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      assert event["properties"]["$geoip_disable"] == true
      refute Map.has_key?(event["properties"], "$ip")
    end

    test "forwards the end user's IP when the caller knows it" do
      Analytics.capture("agent.created", @user_id, %{}, request_ip: "203.0.113.9")

      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      assert event["properties"]["$ip"] == "203.0.113.9"
    end

    test "stamps the flags already known for the person" do
      Application.put_env(:fountain, :feature_flag_overrides, %{"openai_compat" => true})

      Analytics.capture("agent.created", @user_id)

      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      assert event["properties"]["$feature/openai_compat"] == true
    end

    test "never makes a flag lookup happen" do
      Req.Test.stub(Fountain.FeatureFlags, fn _conn ->
        flunk("capture must not trigger a flag lookup")
      end)

      Analytics.capture("agent.created", @user_id)
      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      refute Enum.any?(event["properties"], fn {k, _} -> String.starts_with?(k, "$feature/") end)
    end
  end

  describe "identify/2" do
    setup do
      posthog_on()
      stub_capture()
      :ok
    end

    test "sets the account's shape as person properties" do
      Analytics.identify(user(%{comped: true, role: "admin"}))

      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      assert event["event"] == "$identify"
      set = event["properties"]["$set"]
      assert set["comped"] == true
      assert set["role"] == "admin"
      assert set["email_verified"] == false
      assert set["onboarded"] == false
      assert event["properties"]["$set_once"]["signed_up_at"] == "2026-01-01T00:00:00Z"
    end

    test "carries the email by default" do
      Analytics.identify(user())

      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      assert event["properties"]["$set"]["email"] == "someone@example.com"
    end

    test "POSTHOG_PERSON_PII=false leaves the person pseudonymous" do
      Application.put_env(:fountain, :analytics_person_pii, false)

      Analytics.identify(user())

      assert_receive {:posthog, "/batch/", %{"batch" => [event]}}
      set = event["properties"]["$set"]
      refute Map.has_key?(set, "email")
      refute Map.has_key?(set, "$email")
      assert set["role"] == "user"
    end
  end

  describe "product_event?/2" do
    test "an ordinary context action is a product event" do
      assert Analytics.product_event?("agent.created", "ui")
      assert Analytics.product_event?("conversation.created", "api")
      assert Analytics.product_event?("team.member.added", "self")
      assert Analytics.product_event?("credit.expired", "system:credit_expirer")
    end

    test "the api pipeline's request-log row is not" do
      # ADR 0013 §4 writes one of these per API mutation, named after the
      # request line. Its name carries a resource id, so PostHog would register
      # a new event definition for every conversation anyone touched.
      refute Analytics.product_event?("POST /api/conversations", "api")

      refute Analytics.product_event?(
               "DELETE /api/agents/02100b96-193b-4bdf-b9d9-d1f6e356061d",
               "api"
             )

      refute Analytics.product_event?("GET /api/agents", "api")
    end

    test "an API key the system issued itself is not" do
      refute Analytics.product_event?("api_key.created", "self")
      refute Analytics.product_event?("api_key.created", "system:conversation_server")
      refute Analytics.product_event?("api_key.revoked", "system:buzz_harness")
      refute Analytics.product_event?("api_key.created", nil)
    end

    test "an API key a person minted is" do
      assert Analytics.product_event?("api_key.created", "ui")
      assert Analytics.product_event?("api_key.revoked", "ui")
      assert Analytics.product_event?("api_key.created", "api")
    end

    test "a name outside the closed vocabulary is refused" do
      refute Analytics.product_event?("Agent.Created", "ui")
      refute Analytics.product_event?("agent created", "ui")
      refute Analytics.product_event?("agent", "ui")
      refute Analytics.product_event?("", "ui")
      refute Analytics.product_event?(nil, "ui")
    end
  end

  describe "sanitize/1" do
    test "passes scalars through" do
      assert Analytics.sanitize(%{"provider" => "sprites", "count" => 3, "ok" => true}) ==
               %{"provider" => "sprites", "count" => 3, "ok" => true}
    end

    test "drops anything whose key names a value we must not export" do
      sanitized =
        Analytics.sanitize(%{
          "key" => "GITHUB_TOKEN",
          "value" => "ghp_realsecret",
          "secret_value" => "x",
          "prompt" => "do the thing",
          "output" => "...",
          "provider" => "sprites"
        })

      assert sanitized == %{"provider" => "sprites"}
    end

    test "keeps sizes and counts, which are what the audit rule records instead" do
      assert Analytics.sanitize(%{"secret_count" => 4, "value_bytes" => 40, "has_token" => true}) ==
               %{"secret_count" => 4, "value_bytes" => 40, "has_token" => true}
    end

    test "replaces nested structures with their size" do
      assert Analytics.sanitize(%{"fields" => ["a", "b"], "nested" => %{"a" => 1}}) ==
               %{"fields" => 2, "nested" => 1}
    end

    test "truncates a long string" do
      long = String.duplicate("a", 500)
      assert %{"reason" => truncated} = Analytics.sanitize(%{"reason" => long})
      assert String.length(truncated) == 201
    end

    test "tolerates nil and non-maps" do
      assert Analytics.sanitize(nil) == %{}
      assert Analytics.sanitize("nope") == %{}
    end
  end

  describe "a failing PostHog" do
    setup do
      posthog_on()
      :ok
    end

    test "is dropped, counted, and never raised at the caller" do
      Req.Test.stub(Analytics, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      handler = {__MODULE__, make_ref()}
      test = self()

      :telemetry.attach(
        handler,
        [:fountain, :analytics, :dropped],
        fn _event, measurements, metadata, _ ->
          send(test, {:dropped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = Analytics.capture("agent.created", @user_id)
      assert_receive {:dropped, %{count: 1}, %{reason: reason}}
      assert reason =~ "econnrefused"
    end

    test "a non-2xx answer is dropped too" do
      Req.Test.stub(Analytics, fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)

      assert :ok = Analytics.capture("agent.created", @user_id)
    end
  end
end
