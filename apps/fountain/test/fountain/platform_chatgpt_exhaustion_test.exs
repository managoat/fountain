defmodule Fountain.PlatformChatGPTExhaustionTest do
  @moduledoc """
  An exhausted ChatGPT grant (#2362, ADR 0047 decision 6 as amended): a
  codex turn on the grant that fails with `usageLimitExceeded` records the
  reset time, and selection skips the grant for the platform OpenAI key until
  it passes. Reading the refusal, recording it only for the platform grant,
  and the selection around the reset time.

  `async: false`: one platform row, one advisory lock, and the platform key
  in the application environment, as in `Fountain.PlatformChatGPTTest`.
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

  @sentence "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to " <>
              "purchase more credits or try again at Sep 20th, 2026 11:40 AM."

  # The `session/prompt` error codex-acp 1.10.0 answers with (createTurnErrorData).
  defp usage_error(message \\ @sentence) do
    %{
      "code" => -32_603,
      "message" => "Internal error",
      "data" => %{"codexErrorInfo" => "usageLimitExceeded", "message" => message}
    }
  end

  @now ~U[2026-09-16 20:00:00Z]

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
    stub_auth(%{})
    :ok
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

  # The bound source a turn on the grant carries: identity and generation.
  defp grant_source(user) do
    {:ok, %Source{kind: :codex_chatgpt_access_token} = source, _} = resolve(user)
    source
  end

  defp exhaust!(source, seconds) do
    until = DateTime.add(DateTime.utc_now(), seconds, :second)
    assert {:ok, :recorded} = ChatGPTAccounts.platform_record_exhausted(source, until, :provider)
    until
  end

  describe "UsageLimit.exhaustion/2" do
    test "reads the provider's dated reset, as UTC" do
      assert {:ok, ~U[2026-09-20 11:40:00Z], :provider} =
               UsageLimit.exhaustion(usage_error(), @now)

      assert {:ok, ~U[2026-09-17 00:05:00Z], :provider} =
               UsageLimit.exhaustion(usage_error("try again at Sep 17th, 2026 12:05 AM."), @now)

      assert {:ok, ~U[2026-09-21 13:00:00Z], :provider} =
               UsageLimit.exhaustion(usage_error("try again at Sep 21st, 2026 1:00 PM."), @now)
    end

    test "a bare time is today when still ahead, else tomorrow" do
      assert {:ok, ~U[2026-09-16 23:15:00Z], :provider} =
               UsageLimit.exhaustion(usage_error("or try again at 11:15 PM."), @now)

      assert {:ok, ~U[2026-09-17 09:30:00Z], :provider} =
               UsageLimit.exhaustion(usage_error("or try again at 9:30 AM."), @now)
    end

    test "an unreadable, past or implausibly distant reset is the default window" do
      default = DateTime.add(@now, UsageLimit.default_window_seconds(), :second)

      for message <- [
            "You've hit your usage limit. Try again later.",
            "try again at Sep 1st, 2026 11:40 AM.",
            "try again at Dec 25th, 2026 11:40 AM.",
            "try again at Foo 20th, 2026 11:40 AM.",
            "try again at Sep 31st, 2026 11:40 AM."
          ] do
        assert {:ok, ^default, :default} = UsageLimit.exhaustion(usage_error(message), @now),
               message
      end
    end

    test "finds the kind anywhere in the payload, and nothing else is a usage limit" do
      nested = %{
        "code" => -32_603,
        "data" => %{"details" => "codexErrorInfo: usageLimitExceeded"}
      }

      assert {:ok, _, :default} = UsageLimit.exhaustion(nested, @now)

      assert UsageLimit.exhaustion(%{"code" => -32_603, "message" => "rateLimitExceeded"}, @now) ==
               :none

      assert UsageLimit.exhaustion(%{"message" => "try again at Sep 20th, 2026 11:40 AM."}, @now) ==
               :none
    end
  end

  describe "PlatformInference.credential_for/2 around the reset" do
    test "skips an exhausted grant for the platform key until the reset, then takes it again" do
      user = insert_verified_user()
      access = access_token()
      connect!(%{access_token: access})
      Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")
      source = grant_source(user)

      assert {:ok, :codex_chatgpt_access_token, ^access} =
               PlatformInference.credential_for("openai", "codex")

      until = exhaust!(source, 3_600)
      assert ChatGPTAccounts.platform_exhausted_until() == DateTime.truncate(until, :second)

      assert {:ok, :openai_api_key, "sk-platform"} =
               PlatformInference.credential_for("openai", "codex")

      assert {:ok, %Source{scope: :platform, kind: :openai_api_key} = fallback,
              %{openai_api_key: "sk-platform"} = creds} = resolve(user)

      refute Map.has_key?(creds, :codex_chatgpt_access_token)
      # The gate sees what selection chose: a platform source, under the ceiling.
      assert :ok = PlatformInference.gate_source(fallback)

      # The reset passes: nothing writes, and the grant wins again.
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
      user = insert_verified_user()
      access = access_token()
      connect!(%{access_token: access})
      Application.delete_env(:fountain, :platform_openai_api_key)
      exhaust!(grant_source(user), 3_600)

      assert {:ok, :codex_chatgpt_access_token, ^access} =
               PlatformInference.credential_for("openai", "codex")
    end
  end

  describe "ChatGPTAccounts.platform_record_exhausted/4" do
    test "records once on the grant the turn ran on, with the trail and no token" do
      user = insert_verified_user()
      access = access_token()
      connect!(%{access_token: access, refresh_token: "rt_secret"})
      source = grant_source(user)
      until = ~U[2099-01-01 00:00:00Z]

      assert {:ok, :recorded} =
               ChatGPTAccounts.platform_record_exhausted(source, until, :provider, @now)

      assert %Account{usage_exhausted_at: @now, usage_exhausted_until: ^until, status: "active"} =
               Repo.one!(Account)

      assert [event] = events()
      assert is_nil(event.actor_user_id)
      assert event.metadata["actor"] == "system:platform_chatgpt"
      assert event.metadata["until"] == "2099-01-01T00:00:00Z"
      assert event.metadata["reset"] == "provider"
      assert event.metadata["account_id"] == "acct_platform_1"
      refute inspect(event.metadata) =~ access
      refute inspect(event.metadata) =~ "rt_secret"

      # Several in-flight turns fail together: one row change, one event.
      assert {:ok, :unchanged} =
               ChatGPTAccounts.platform_record_exhausted(source, until, :provider, @now)

      # A default window does not extend a reset that is still running.
      assert {:ok, :unchanged} =
               ChatGPTAccounts.platform_record_exhausted(
                 source,
                 ~U[2099-06-01 00:00:00Z],
                 :default,
                 @now
               )

      assert length(events()) == 1

      assert %{status: "active", exhausted_until: ^until} = ChatGPTAccounts.platform_status()
    end

    test "ignores any source but the platform grant, and a grant since replaced" do
      user = insert_verified_user()
      connect!()
      source = grant_source(user)
      until = DateTime.add(DateTime.utc_now(), 3_600, :second)

      for other <- [
            nil,
            %Source{scope: :credential, kind: :openai_api_key, identity: "credential:x"},
            %Source{source | scope: :tenant_secret},
            %Source{source | kind: :openai_api_key},
            %Source{scope: :platform, kind: :openai_api_key, identity: "platform:stored:openai"}
          ] do
        assert :ignored = ChatGPTAccounts.platform_record_exhausted(other, until, :provider)
      end

      # A reconnect replaces the generation: a late report from the old one
      # changes nothing.
      connect!(%{
        account_id: "acct_platform_2",
        id_token: id_token(%{account_id: "acct_platform_2"})
      })

      assert {:ok, :unchanged} =
               ChatGPTAccounts.platform_record_exhausted(source, until, :provider)

      assert ChatGPTAccounts.platform_exhausted_until() == nil
      assert events() == []
    end

    test "a reconnect of the same account keeps the exhaustion; a different account clears it" do
      user = insert_verified_user()
      connect!()
      until = exhaust!(grant_source(user), 3_600) |> DateTime.truncate(:second)

      # Usage limits belong to the account, not the token (#2362).
      connect!(%{refresh_token: "rt_two"})
      assert ChatGPTAccounts.platform_exhausted_until() == until

      connect!(%{id_token: id_token(%{account_id: "acct_platform_2"})})
      assert ChatGPTAccounts.platform_exhausted_until() == nil
      assert %Account{usage_exhausted_at: nil} = Repo.one!(Account)
    end
  end

  describe "TurnMachine: a failed prompt on the grant" do
    setup do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "codex")
      conv = insert_conversation(user_id: user.id, agent: agent)
      row = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

      machine = %TurnMachine{
        conversation_id: conv.id,
        sandbox_id: conv.sandbox_id,
        row: row,
        metrics: TurnMachine.start_metrics("codex", :runner, System.monotonic_time(:millisecond))
      }

      %{user: user, machine: machine}
    end

    test "records the exhaustion, and the turn still fails with nothing retried", %{
      user: user,
      machine: machine
    } do
      connect!()
      source = grant_source(user)
      reason = {:acp_error, :prompt, usage_error("or try again at 11:59 PM.")}

      assert {_turn, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(machine, {:failed, reason}, %{inference: source})

      assert %DateTime{} = ChatGPTAccounts.platform_exhausted_until()
      assert [%{metadata: %{"reset" => "provider"}}] = events()
    end

    test "records nothing when the turn ran on a tenant's own key or on the platform key", %{
      user: user,
      machine: machine
    } do
      connect!()
      grant = grant_source(user)
      reason = {:acp_error, :prompt, usage_error()}

      for source <- [
            %Source{scope: :credential, kind: :openai_api_key, identity: "credential:x:openai"},
            %Source{scope: :platform, kind: :openai_api_key, identity: "platform:stored:openai"},
            # Scope and kind decide, not an identity string that happens to match.
            %Source{grant | scope: :credential, kind: :openai_api_key},
            %Source{grant | scope: :tenant_secret},
            nil
          ] do
        assert {_turn, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
                 TurnMachine.handle(machine, {:failed, reason}, %{inference: source})
      end

      # And a grant turn that failed for another reason records nothing either.
      TurnMachine.handle(
        machine,
        {:failed, {:acp_error, :prompt, %{"code" => -32_603, "message" => "boom"}}},
        %{inference: grant}
      )

      assert ChatGPTAccounts.platform_exhausted_until() == nil
      assert events() == []
    end
  end
end
