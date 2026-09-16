defmodule Fountain.PlatformChatGPTExhaustionTest do
  @moduledoc """
  An exhausted ChatGPT grant (#2362, ADR 0047 decision 6 as amended). A
  sandbox's `usageLimitExceeded` is only a hint, because a tenant can forge
  it; the server confirms with the ChatGPT backend's `/wham/usage` before it
  records anything, and selection then skips the grant for the platform
  OpenAI key until the backend's reset time.

  The backend is stubbed through the same `Req.Test` seam the refresh tests
  use (`:platform_chatgpt_req_options`); nothing here reaches OpenAI.

  `async: false`: one platform row, one advisory lock, the shared `Req.Test`
  stub, and the platform key in the application environment, as in
  `Fountain.PlatformChatGPTTest`.
  """

  use Fountain.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.AdminEvent
  alias Fountain.ChatGPTAccounts
  alias Fountain.Conversations.TurnMachine
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.{Account, UsageLimit}
  alias Fountain.PlatformInference
  alias Fountain.Repo

  @usage_path "/backend-api/wham/usage"
  @now ~U[2026-09-16 20:00:00Z]
  @reset ~U[2026-09-20 11:40:00Z]

  # The `session/prompt` error codex-acp 1.10.0 answers with
  # (`createTurnErrorData`), and exactly what a fake adapter can print.
  @forged_error %{
    "code" => -32_603,
    "message" => "Internal error",
    "data" => %{
      "codexErrorInfo" => "usageLimitExceeded",
      "message" => "You've hit your usage limit. Try again at Sep 20th, 2026 11:40 AM."
    }
  }

  setup do
    original = Application.get_env(:fountain, :platform_openai_api_key)

    previous_broker =
      for key <- [:broker_listen_port, :broker_proxy_url],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      if original,
        do: Application.put_env(:fountain, :platform_openai_api_key, original),
        else: Application.delete_env(:fountain, :platform_openai_api_key)

      for {key, value} <- previous_broker do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    # The grant is selected only on a brokered deployment.
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")
    stub_auth(%{})
    :ok
  end

  # `/wham/usage` answering for the account, reporting each call to the test.
  defp stub_usage(body, status \\ 200) do
    test = self()

    stub_auth(%{
      @usage_path => fn _ ->
        send(test, :usage_checked)
        {status, body}
      end
    })
  end

  defp limited_body(reset \\ @reset) do
    %{
      "plan_type" => "pro",
      "rate_limit" => %{
        "allowed" => false,
        "limit_reached" => true,
        "primary_window" => %{
          "used_percent" => 40,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 600,
          "reset_at" => DateTime.to_unix(@now) + 600
        },
        "secondary_window" => %{
          "used_percent" => 100,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => DateTime.diff(reset, @now),
          "reset_at" => DateTime.to_unix(reset)
        }
      },
      "credits" => %{"has_credits" => false, "unlimited" => false}
    }
  end

  defp not_limited_body do
    %{
      "plan_type" => "pro",
      "rate_limit" => %{
        "allowed" => true,
        "limit_reached" => false,
        "primary_window" => %{"used_percent" => 3, "reset_at" => DateTime.to_unix(@now) + 600}
      },
      "credits" => %{"has_credits" => false, "unlimited" => false}
    }
  end

  defp events do
    Repo.all(
      from e in AdminEvent,
        where: e.event_type == "admin.platform_chatgpt.exhausted",
        order_by: e.id
    )
  end

  defp resolve(user),
    do: InferenceCredentials.resolve(user.id, "openai/gpt-5.5-codex", "codex", [])

  defp grant_source(user) do
    {:ok, %Source{kind: :codex_chatgpt_access_token} = source, _} = resolve(user)
    source
  end

  defp machine_for(user) do
    agent = insert_agent(user_id: user.id, runtime: "codex")
    conv = insert_conversation(user_id: user.id, agent: agent)
    row = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

    %TurnMachine{
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      row: row,
      metrics: TurnMachine.start_metrics("codex", :runner, System.monotonic_time(:millisecond))
    }
  end

  # Report the hint the way the server does, then wait for the background
  # check it started.
  defp fail_with_hint(machine, source, error \\ @forged_error) do
    result =
      TurnMachine.handle(machine, {:failed, {:acp_error, :prompt, error}}, %{inference: source})

    Fountain.DataCase.drain_best_effort_tasks(self())
    result
  end

  describe "the two-tenant regression (review of #2363)" do
    test "a forged adapter error the backend does not confirm leaves another tenant's source alone" do
      victim = insert_verified_user()
      attacker = insert_verified_user()
      access = access_token()
      connect!(%{access_token: access})

      assert {:ok, %Source{scope: :platform, kind: :codex_chatgpt_access_token} = before, _} =
               resolve(victim)

      stub_usage(not_limited_body())

      assert {_turn, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
               fail_with_hint(machine_for(attacker), grant_source(attacker))

      assert_received :usage_checked
      assert {:ok, ^before, %{codex_chatgpt_access_token: ^access}} = resolve(victim)
      assert ChatGPTAccounts.platform_exhausted_until() == nil
      assert %Account{usage_exhausted_at: nil} = Repo.one!(Account)
      assert events() == []
    end

    test "a limit the backend confirms flips the other tenant to the platform key" do
      victim = insert_verified_user()
      tenant = insert_verified_user()
      connect!()
      reset = DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.truncate(:second)
      stub_usage(limited_body(reset))

      fail_with_hint(machine_for(tenant), grant_source(tenant))

      assert_received :usage_checked
      assert ChatGPTAccounts.platform_exhausted_until() == reset

      assert {:ok, %Source{scope: :platform, kind: :openai_api_key} = fallback,
              %{openai_api_key: "sk-platform"} = creds} = resolve(victim)

      refute Map.has_key?(creds, :codex_chatgpt_access_token)
      assert :ok = PlatformInference.gate_source(fallback)
    end
  end

  describe "ChatGPTAccounts.platform_confirm_exhausted/2" do
    test "records the backend's reset once, with the trail and no token" do
      user = insert_verified_user()
      access = access_token()
      connect!(%{access_token: access, refresh_token: "rt_secret"})
      source = grant_source(user)
      test = self()

      stub_auth(%{
        @usage_path => fn _ ->
          send(test, {:usage_headers, :called})
          {200, limited_body()}
        end
      })

      assert :recorded = ChatGPTAccounts.platform_confirm_exhausted(source, @now)
      assert_received {:usage_headers, :called}

      assert %Account{usage_exhausted_at: @now, usage_exhausted_until: @reset, status: "active"} =
               Repo.one!(Account)

      assert [event] = events()
      assert is_nil(event.actor_user_id)
      assert event.metadata["actor"] == "system:platform_chatgpt"
      assert event.metadata["until"] == "2026-09-20T11:40:00Z"
      assert event.metadata["account_id"] == "acct_platform_1"
      refute inspect(event.metadata) =~ access
      refute inspect(event.metadata) =~ "rt_secret"
    end

    test "sends the grant's token and account id, and only to the usage endpoint" do
      user = insert_verified_user()
      access = access_token()
      connect!(%{access_token: access})
      test = self()

      Req.Test.stub(Fountain.PlatformChatGPT.OAuth, fn conn ->
        send(
          test,
          {:request, conn.method, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "chatgpt-account-id")}
        )

        Req.Test.json(conn, not_limited_body())
      end)

      assert :not_limited = ChatGPTAccounts.platform_confirm_exhausted(grant_source(user), @now)
      bearer = "Bearer " <> access
      assert_received {:request, "GET", @usage_path, [^bearer], ["acct_platform_1"]}
    end

    test "not limited, a failed call, or an unreadable body records nothing" do
      user = insert_verified_user()
      connect!()
      source = grant_source(user)

      for {body, status, expected} <- [
            {not_limited_body(), 200, :not_limited},
            {%{"error" => "nope"}, 401, {:error, {:usage, 401}}},
            {%{"unexpected" => true}, 200, {:error, :unexpected_usage_body}}
          ] do
        Repo.update_all(Account, set: [usage_checked_at: nil])
        stub_usage(body, status)
        assert ^expected = ChatGPTAccounts.platform_confirm_exhausted(source, @now)
        assert_received :usage_checked
      end

      assert %Account{usage_exhausted_until: nil, usage_exhausted_at: nil} = Repo.one!(Account)
      assert events() == []
    end

    test "one check per cooldown, however many hints arrive" do
      user = insert_verified_user()
      connect!()
      source = grant_source(user)
      stub_usage(not_limited_body())

      assert :not_limited = ChatGPTAccounts.platform_confirm_exhausted(source, @now)
      assert_received :usage_checked

      for _ <- 1..5 do
        assert :throttled = ChatGPTAccounts.platform_confirm_exhausted(source, @now)
      end

      refute_received :usage_checked

      later = DateTime.add(@now, ChatGPTAccounts.platform_usage_check_cooldown_seconds(), :second)
      assert :not_limited = ChatGPTAccounts.platform_confirm_exhausted(source, later)
      assert_received :usage_checked
    end

    test "concurrent hints make one call" do
      user = insert_verified_user()
      connect!()
      source = grant_source(user)
      stub_usage(not_limited_body())

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> ChatGPTAccounts.platform_confirm_exhausted(source, @now) end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &(&1 == :not_limited)) == 1
      assert Enum.count(results, &(&1 == :throttled)) == 7
    end

    test "an exhaustion already recorded is not checked again" do
      user = insert_verified_user()
      connect!()
      source = grant_source(user)
      Repo.update_all(Account, set: [usage_exhausted_until: @reset])
      stub_usage(limited_body())

      assert :already = ChatGPTAccounts.platform_confirm_exhausted(source, @now)
      refute_received :usage_checked
    end

    test "ignores any source but the platform grant, and a grant since replaced" do
      user = insert_verified_user()
      connect!()
      source = grant_source(user)
      stub_usage(limited_body())

      for other <- [
            nil,
            %Source{scope: :credential, kind: :openai_api_key, identity: "credential:x"},
            %Source{source | scope: :tenant_secret},
            %Source{source | kind: :openai_api_key},
            %Source{scope: :platform, kind: :openai_api_key, identity: "platform:stored:openai"}
          ] do
        assert :ignored = ChatGPTAccounts.platform_confirm_exhausted(other, @now)
        assert :ignored = ChatGPTAccounts.platform_check_exhaustion(other)
      end

      connect!(%{id_token: id_token(%{account_id: "acct_platform_2"})})
      assert :ignored = ChatGPTAccounts.platform_confirm_exhausted(source, @now)

      refute_received :usage_checked
      assert ChatGPTAccounts.platform_exhausted_until() == nil
      assert events() == []
    end
  end

  describe "PlatformInference.credential_for/2 around the reset" do
    test "skips a confirmed exhaustion for the key until the reset, then takes the grant again" do
      user = insert_verified_user()
      access = access_token()
      connect!(%{access_token: access})
      reset = DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.truncate(:second)
      stub_usage(limited_body(reset))

      assert {:ok, :codex_chatgpt_access_token, ^access} =
               PlatformInference.credential_for("openai", "codex")

      assert :recorded = ChatGPTAccounts.platform_confirm_exhausted(grant_source(user))

      assert {:ok, :openai_api_key, "sk-platform"} =
               PlatformInference.credential_for("openai", "codex")

      Repo.update_all(Account,
        set: [
          usage_exhausted_until:
            DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)
        ]
      )

      assert ChatGPTAccounts.platform_exhausted_until() == nil

      assert {:ok, :codex_chatgpt_access_token, ^access} =
               PlatformInference.credential_for("openai", "codex")
    end

    test "with no platform key to fall back to, the exhausted grant is still selected" do
      access = access_token()
      connect!(%{access_token: access})
      Application.delete_env(:fountain, :platform_openai_api_key)
      Repo.update_all(Account, set: [usage_exhausted_until: ~U[2099-01-01 00:00:00Z]])

      assert {:ok, :codex_chatgpt_access_token, ^access} =
               PlatformInference.credential_for("openai", "codex")
    end

    test "a reconnect of the same account keeps the exhaustion; a different account clears it" do
      connect!()
      Repo.update_all(Account, set: [usage_exhausted_until: ~U[2099-01-01 00:00:00Z]])

      connect!(%{refresh_token: "rt_two"})
      assert ChatGPTAccounts.platform_exhausted_until() == ~U[2099-01-01 00:00:00Z]

      connect!(%{id_token: id_token(%{account_id: "acct_platform_2"})})
      assert ChatGPTAccounts.platform_exhausted_until() == nil
    end
  end

  describe "TurnMachine: what starts a check" do
    test "no check for a tenant's own key, the platform key, or a grant turn failing otherwise" do
      user = insert_verified_user()
      connect!()
      grant = grant_source(user)
      machine = machine_for(user)
      stub_usage(limited_body())

      for source <- [
            %Source{scope: :credential, kind: :openai_api_key, identity: "credential:x:openai"},
            %Source{scope: :platform, kind: :openai_api_key, identity: "platform:stored:openai"},
            %Source{grant | scope: :credential, kind: :openai_api_key},
            %Source{grant | scope: :tenant_secret},
            nil
          ] do
        assert {_turn, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
                 fail_with_hint(machine, source)
      end

      fail_with_hint(machine, grant, %{"code" => -32_603, "message" => "boom"})

      refute_received :usage_checked
      assert ChatGPTAccounts.platform_exhausted_until() == nil
    end
  end

  describe "UsageLimit" do
    test "hint?/1 recognises the adapter's shape and nothing else" do
      assert UsageLimit.hint?(@forged_error)
      assert UsageLimit.hint?(%{"data" => %{"details" => "codexErrorInfo: usageLimitExceeded"}})
      refute UsageLimit.hint?(%{"code" => -32_603, "message" => "rateLimitExceeded"})
    end

    test "limited/2 reads allowed, limit_reached, credits and the spent window's reset" do
      assert {:limited, @reset} = UsageLimit.limited(limited_body(), @now)

      assert :not_limited = UsageLimit.limited(not_limited_body(), @now)

      with_credits =
        limited_body()
        |> put_in(["rate_limit", "allowed"], true)
        |> put_in(["credits", "has_credits"], true)

      assert :not_limited = UsageLimit.limited(with_credits, @now)

      no_reset =
        put_in(limited_body(), ["rate_limit"], %{"allowed" => false, "limit_reached" => true})

      default = DateTime.add(@now, UsageLimit.default_window_seconds(), :second)
      assert {:limited, ^default} = UsageLimit.limited(no_reset, @now)

      far = limited_body(DateTime.add(@now, 30 * 86_400, :second))
      cap = DateTime.add(@now, UsageLimit.max_window_seconds(), :second)
      assert {:limited, ^cap} = UsageLimit.limited(far, @now)

      after_seconds =
        put_in(limited_body(), ["rate_limit", "secondary_window"], %{
          "used_percent" => 100,
          "reset_after_seconds" => 7_200
        })

      assert {:limited, ~U[2026-09-16 22:00:00Z]} = UsageLimit.limited(after_seconds, @now)
      assert {:error, :unexpected_usage_body} = UsageLimit.limited(%{}, @now)
    end
  end
end
