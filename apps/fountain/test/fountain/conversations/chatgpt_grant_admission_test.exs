defmodule Fountain.Conversations.ChatGPTGrantAdmissionTest do
  @moduledoc """
  What admission does with a credential set that names a ChatGPT
  subscription (ADR 0060 stages 2 and 3), through the real launch doors.

    * an unusable grant is `{:chatgpt_grant_unusable, _}`, naming it, and the
      launch does not land on the set's key or on platform inference, and
      leaves no row behind;
    * a usable one launches, bound to that grant and generation. Stage 2
      refused it as `:chatgpt_grant_transport_unavailable` while nothing could
      carry a user's grant into a sandbox; stage 3 built the transport and
      deleted the guard, and the four tests that pinned it became these;
    * every turn renews the grant by id and generation, outside the source
      lock, and one that can no longer serve refuses the turn by name;
    * a grant at its usage limit (stage 5) refuses the launch and the turn
      with the reset time while every other source the account and the
      deployment hold is usable, and is admitted again once the time passes.

  `async: false`: the broker is application env and the platform grant is
  connected.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import Fountain.ChatGPTFixtures

  alias Fountain.ChatGPTAccounts
  alias Fountain.Conversations.{Conversation, InferenceBinding, Launch, Sandbox, TurnMachine}
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source

  setup do
    stub_server_start(fn _sup, _spec -> {:ok, spawn(fn -> :ok end)} end)

    restore =
      for key <- [:broker_listen_port, :broker_proxy_url, :platform_openai_api_key],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- restore do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")
    connect!()

    user = insert_active_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    grant = user_grant!(user.id, %{name: "Work"})
    {:ok, set} = InferenceCredentials.create_set(user.id, "Subscription")
    {:ok, set} = InferenceCredentials.put_credential_in(set, dek, :openai_api_key, "sk-own")
    {:ok, set} = InferenceCredentials.set_grant(set, grant.id)
    agent = insert_agent(user_id: user.id, runtime: "codex", inference_credential_id: set.id)

    %{user: user, grant: grant, set: set, agent: agent}
  end

  defp rows(user) do
    {Repo.aggregate(from(c in Conversation, where: c.user_id == ^user.id), :count),
     Repo.aggregate(from(s in Sandbox, where: s.user_id == ^user.id), :count)}
  end

  defp launch(ctx, extra) do
    Launch.start_conversation(
      Map.merge(%{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id}, extra)
    )
  end

  for door <- [:fresh, :attach] do
    test "#{door}: an unusable named grant refuses the launch by name, with no fallback", ctx do
      :ok = ChatGPTAccounts.disconnect_for_user(ctx.grant.id, ctx.user.id)

      extra =
        case unquote(door) do
          :fresh ->
            %{"sandbox_mode" => "ephemeral"}

          :attach ->
            sandbox =
              insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

            %{"sandbox_id" => sandbox.id}
        end

      before = rows(ctx.user)

      assert {:error, {:chatgpt_grant_unusable, detail}} = launch(ctx, extra)
      assert %{grant_id: id, name: "Work", reason: :disconnected} = detail
      assert id == ctx.grant.id
      assert rows(ctx.user) == before
    end

    test "#{door}: a usable named grant launches, bound to that grant and generation", ctx do
      extra =
        case unquote(door) do
          :fresh ->
            %{"sandbox_mode" => "ephemeral"}

          :attach ->
            # A machine first bound under stage 3 (`codex_peer_homes`): one
            # bound before it keeps the one-source rule for every source.
            sandbox =
              insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

            sandbox |> Ecto.Changeset.change(codex_peer_homes: true) |> Repo.update!()
            %{"sandbox_id" => sandbox.id}
        end

      assert {:ok, conv} = launch(ctx, extra)

      assert %{
               "scope" => "grant",
               "origin" => "own",
               "kind" => "codex_chatgpt_access_token",
               "grant_id" => grant_id,
               "generation" => generation
             } = conv.inference_source

      assert grant_id == ctx.grant.id
      assert generation == ctx.grant.generation

      # A subscription has a home of its own, so it is not the machine's binding.
      machine = Repo.get!(Sandbox, conv.sandbox_id)
      assert machine.codex_peer_homes
      assert is_nil(machine.codex_inference_source)
    end
  end

  test "a launch that overrides the set with one naming no grant is not affected", ctx do
    {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
    {:ok, plain} = InferenceCredentials.create_set(ctx.user.id, "Key only")
    {:ok, plain} = InferenceCredentials.put_credential_in(plain, dek, :openai_api_key, "sk-key")

    assert {:ok, conv} =
             launch(ctx, %{
               "sandbox_mode" => "ephemeral",
               "inference_credential_id" => plain.id
             })

    assert %{"scope" => "credential", "kind" => "openai_api_key"} = conv.inference_source
    refute Map.has_key?(conv.inference_source, "grant_id")
  end

  test "reserve/2 binds a conversation to a grant source, and the machine records nothing", ctx do
    {:ok, %Source{scope: :grant} = source, credentials} =
      InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, "codex",
        credential_set_id: ctx.set.id
      )

    # What the runtime is handed: the grant's placeholder, never a bearer, and
    # never the set's own key beside it.
    assert credentials == %{
             codex_chatgpt_access_token: ChatGPTAccounts.Reserved.placeholder(ctx.grant.id)
           }

    sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "pending")

    conv =
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox_id: sandbox.id,
        runtime: "codex"
      )

    assert :ok = InferenceBinding.reserve(conv, source)
    assert Repo.reload!(conv).inference_source == Source.dump(source)
    assert is_nil(Repo.reload!(sandbox).codex_inference_source)
    assert Repo.reload!(sandbox).codex_peer_homes
  end

  describe "a turn on a grant" do
    setup ctx do
      {:ok, %Source{scope: :grant} = source, _} =
        InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, "codex",
          credential_set_id: ctx.set.id
        )

      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox_id: sandbox.id,
          runtime: "codex"
        )

      conv |> Ecto.Changeset.change(inference_source: Source.dump(source)) |> Repo.update!()
      %{source: source, sandbox: sandbox, conv: conv}
    end

    test "both doors admit it", ctx do
      # The fixture's token is inside its refresh margin, so the gate renews.
      stub_refresh(%{
        expect_refresh: "rt_user",
        id_token: id_token(%{account_id: ctx.grant.account_id})
      })

      assert :ok = TurnMachine.gate(ctx.user.id, ctx.source)

      assert {:ok, _turn} =
               Fountain.Conversations._unsafe_create_turn_on_sandbox(
                 %{
                   conversation_id: ctx.conv.id,
                   turn_number: 1,
                   prompt: "hi",
                   status: "running",
                   started_at: DateTime.utc_now() |> DateTime.truncate(:second)
                 },
                 ctx.sandbox.id
               )
    end

    # Stage 2 left this to stage 3: nothing on the turn path renewed a user's
    # grant, so one resolved usable and died at the proxy.
    test "the gate renews a grant inside its refresh margin, by id and generation", ctx do
      renewed = access_token(7_200, %{"renewed" => true})
      other = user_grant!(ctx.user.id, %{refresh_token: "rt_other"})

      stub_refresh(%{
        expect_refresh: "rt_user",
        access_token: renewed,
        id_token: id_token(%{account_id: ctx.grant.account_id})
      })

      assert :ok = TurnMachine.gate(ctx.user.id, ctx.source)

      row = Repo.get!(Fountain.PlatformChatGPT.Account, ctx.grant.id)
      assert {:ok, ^renewed} = ChatGPTAccounts.Cipher.decrypt_token(row, :access_token)
      assert row.generation == ctx.grant.generation
      assert row.lock_version == ctx.grant.lock_version + 1

      # Only the named grant: the user's other one, and the platform's, are as they were.
      assert Repo.get!(Fountain.PlatformChatGPT.Account, other.id) == other

      # Fresh now, so the next turn asks nobody: a second exchange would be
      # refused by the stub as a reused refresh token.
      assert :ok = TurnMachine.gate(ctx.user.id, ctx.source)
    end

    test "a grant the auth server refuses at the gate refuses the turn by name", ctx do
      stub_refusal("invalid_grant")

      assert {:error, {:chatgpt_grant_unusable, detail}} =
               TurnMachine.gate(ctx.user.id, ctx.source)

      assert %{name: "Work", reason: :revoked, grant_id: grant_id} = detail
      assert grant_id == ctx.grant.id
      assert InferenceCredentials.grant_unusable_message(detail) =~ "no longer accepted by OpenAI"
    end

    test "a renewal that may yet succeed lets the turn go ahead on the token it has", ctx do
      stub_auth(%{"/oauth/token" => fn _ -> {503, %{"error" => "temporarily_unavailable"}} end})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = TurnMachine.gate(ctx.user.id, ctx.source)
        end)

      assert log =~ ctx.grant.id
      assert log =~ "refresh_failed"
      refute log =~ "Work"
    end

    # Stage 2's item 4: resolution reads metadata and cannot see whether the
    # owner may still use a grant. The credential side can, and says so in the
    # same tagged refusal, never by reaching for another credential.
    test "an owner who may no longer use a grant is refused by name", ctx do
      ctx.user |> Ecto.Changeset.change(email_verified_at: nil) |> Repo.update!()

      assert :ok = InferenceCredentials.validate_source(ctx.user.id, ctx.source)

      assert {:error,
              {:chatgpt_grant_unusable, %{reason: :owner_ineligible, name: "Work"} = detail}} =
               TurnMachine.gate(ctx.user.id, ctx.source)

      assert InferenceCredentials.grant_unusable_message(detail) =~ "verified account"
    end

    test "a suspended account is told it is suspended, and nothing is renewed", ctx do
      ctx.user |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:second)) |> Repo.update!()
      # No stub for /oauth/token: a renewal here would raise.
      assert {:error, reason} = TurnMachine.gate(ctx.user.id, ctx.source)
      refute match?({:chatgpt_grant_unusable, _}, reason)
    end

    test "every other source costs the gate nothing", ctx do
      for source <- [nil, Source.credential(), Source.platform(), Source.none()] do
        assert :ok = Fountain.Conversations.CodexChatGPT.ensure_fresh(ctx.user.id, source)
      end
    end
  end

  # ADR 0060 decision 4, end to end: the named subscription is at its usage
  # limit while everything it could be swapped for is in place and usable.
  # `setup` connected the platform grant and set `PLATFORM_OPENAI_API_KEY`,
  # and left the user a second usable grant ("Work"); this adds a third, the
  # set's own key, a default set with a key, and an `OPENAI_API_KEY` in the
  # agent's environment and in the launch's vault.
  describe "a named grant at its usage limit, with every other source usable" do
    @usage_path "/backend-api/wham/usage"

    # What codex-acp answers a prompt with at the limit, and what a fake
    # adapter can print.
    @usage_limit_error %{
      "code" => -32_603,
      "message" => "Internal error",
      "data" => %{
        "codexErrorInfo" => "usageLimitExceeded",
        "message" => "You've hit your usage limit."
      }
    }

    setup ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      # Outside its refresh margin, so no turn here asks the auth server.
      main = user_grant!(ctx.user.id, %{name: "Main", access_token: access_token()})
      spare = user_grant!(ctx.user.id, %{name: "Spare", access_token: access_token()})

      {:ok, on_main} = InferenceCredentials.create_set(ctx.user.id, "On main")

      {:ok, on_main} =
        InferenceCredentials.put_credential_in(on_main, dek, :openai_api_key, "sk-set")

      {:ok, on_main} = InferenceCredentials.set_grant(on_main, main.id)
      {:ok, on_spare} = InferenceCredentials.create_set(ctx.user.id, "On spare")
      {:ok, on_spare} = InferenceCredentials.set_grant(on_spare, spare.id)

      {:ok, keys} = InferenceCredentials.create_set(ctx.user.id, "Keys")

      {:ok, keys} =
        InferenceCredentials.put_credential_in(keys, dek, :openai_api_key, "sk-default")

      {:ok, _} = InferenceCredentials.set_default(keys)

      env = insert_env(user_id: ctx.user.id, env_vars: %{"OPENAI_API_KEY" => "sk-env-plain"})
      vault = insert_vault(user_id: ctx.user.id)

      {:ok, _} =
        Fountain.Environments.upsert_secret(
          env,
          %{"key" => "OPENAI_API_KEY", "value" => "sk-env"},
          dek
        )

      {:ok, _} =
        Fountain.Vaults.upsert_secret(
          vault,
          %{"key" => "OPENAI_API_KEY", "value" => "sk-vault"},
          dek
        )

      agent =
        insert_agent(
          user_id: ctx.user.id,
          runtime: "codex",
          inference_credential_id: on_main.id,
          environment_id: env.id
        )

      {:ok, %Source{scope: :grant} = source, _} =
        InferenceCredentials.resolve(ctx.user.id, agent.model, "codex",
          credential_set_id: on_main.id,
          environment_id: env.id,
          vault_id: vault.id
        )

      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: agent,
          sandbox_id: sandbox.id,
          runtime: "codex",
          vault_id: vault.id
        )

      conv |> Ecto.Changeset.change(inference_source: Source.dump(source)) |> Repo.update!()

      %{
        agent: agent,
        main: main,
        spare: spare,
        on_main: on_main,
        on_spare: on_spare,
        env: env,
        vault: vault,
        source: source,
        sandbox: sandbox,
        conv: conv
      }
    end

    defp stub_usage(body) do
      test = self()

      stub_auth(%{
        @usage_path => fn _ ->
          send(test, :usage_checked)
          {200, body}
        end
      })
    end

    defp limited(reset) do
      %{
        "rate_limit" => %{
          "allowed" => false,
          "limit_reached" => true,
          "secondary_window" => %{"used_percent" => 100, "reset_at" => DateTime.to_unix(reset)}
        }
      }
    end

    # The running turn's failure, reported the way the server reports it.
    defp fail_turn(ctx, error, machine_ctx) do
      row = insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())

      machine = %TurnMachine{
        conversation_id: ctx.conv.id,
        sandbox_id: ctx.sandbox.id,
        row: row,
        metrics: TurnMachine.start_metrics("codex", :runner, System.monotonic_time(:millisecond))
      }

      result = TurnMachine.handle(machine, {:failed, {:acp_error, :prompt, error}}, machine_ctx)
      Fountain.DataCase.drain_best_effort_tasks(self())
      result
    end

    defp grant_row(grant), do: Repo.get!(Fountain.PlatformChatGPT.Account, grant.id)

    # Each thing the spent grant could be swapped for resolves, one at a time
    # and by the value it hands the runtime, so "nothing is substituted" is
    # never true only because there was nothing to substitute.
    defp assert_every_alternative_usable(ctx) do
      model = ctx.agent.model
      user_id = ctx.user.id
      resolve = &InferenceCredentials.resolve(user_id, model, &1, &2)

      # The account's default set, which is what no set named means.
      assert {:ok, %Source{scope: :credential, kind: :openai_api_key},
              %{openai_api_key: "sk-default"}} = resolve.("codex", [])

      # `OPENAI_API_KEY` in the environment alone, and in the vault alone.
      assert {:ok, %Source{scope: :tenant_secret, kind: :openai_api_key},
              %{openai_api_key: "sk-env"}} = resolve.("codex", environment_id: ctx.env.id)

      assert {:ok, %Source{scope: :tenant_secret, kind: :openai_api_key},
              %{openai_api_key: "sk-vault"}} = resolve.("codex", vault_id: ctx.vault.id)

      # The user's other subscriptions.
      spare_id = ctx.spare.id

      assert {:ok, %Source{scope: :grant, grant_id: ^spare_id}, _} =
               resolve.("codex", credential_set_id: ctx.on_spare.id)

      work_id = ctx.grant.id

      assert {:ok, %Source{scope: :grant, grant_id: ^work_id}, _} =
               resolve.("codex", credential_set_id: ctx.set.id)

      # The set's own key, which every OpenAI consumer but codex runs on.
      assert {:ok, %Source{scope: :credential, kind: :openai_api_key},
              %{openai_api_key: "sk-set"}} =
               resolve.("opencode", credential_set_id: ctx.on_main.id)

      # The deployment's grant and its key, as an account holding nothing of
      # its own gets them.
      assert Fountain.PlatformInference.enabled?()
      bare = insert_active_user()

      assert {:ok, %Source{scope: :platform, kind: :codex_chatgpt_access_token}, _} =
               InferenceCredentials.resolve(bare.id, model, "codex", [])

      assert {:ok, %Source{scope: :platform, kind: :openai_api_key},
              %{openai_api_key: "sk-platform"}} =
               InferenceCredentials.resolve(bare.id, model, "opencode", [])
    end

    defp admission_refusals(conv) do
      Repo.all(
        from e in Fountain.Conversations.LogEvent,
          where: e.conversation_id == ^conv.id and e.kind == "stage" and e.stage == "sandbox"
      )
    end

    @tag :capture_log
    test "the launch and the turn are refused with the reset time, and nothing is substituted",
         ctx do
      reset = DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.truncate(:second)
      stub_usage(limited(reset))
      assert_every_alternative_usable(ctx)

      # The turn that hit the limit fails as it would have, with nothing retried.
      assert {_turn, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
               fail_turn(ctx, @usage_limit_error, %{inference: ctx.source, user_id: ctx.user.id})

      assert_received :usage_checked
      assert %{usage_exhausted_until: ^reset, status: "active"} = grant_row(ctx.main)
      assert %{usage_exhausted_until: nil} = grant_row(ctx.spare)
      assert %{usage_exhausted_until: nil} = grant_row(ctx.grant)
      assert ChatGPTAccounts.platform_exhausted_until() == nil

      main_id = ctx.main.id
      before = rows(ctx.user)

      for extra <- [
            %{"sandbox_mode" => "ephemeral", "vault_id" => ctx.vault.id},
            %{"sandbox_mode" => "ephemeral"}
          ] do
        assert {:error,
                {:chatgpt_grant_unusable,
                 %{grant_id: ^main_id, name: "Main", reason: :exhausted, until: ^reset} = detail}} =
                 launch(ctx, extra)

        assert InferenceCredentials.grant_unusable_message(detail) =~ "Main"
      end

      assert rows(ctx.user) == before

      # Still all there to be taken, and none was.
      assert_every_alternative_usable(ctx)

      # The conversation already on it: the prompt's wake, then both doors of
      # the turn.
      stub(Managoat.Sandbox.Sprites, :get, fn _ -> {:ok, %{status: :running, raw: %{}}} end)

      assert {:error, {:chatgpt_grant_unusable, %{reason: :exhausted, until: ^reset}}} =
               Fountain.Conversations.Wake.wake_conversation(ctx.conv.id, "hi")

      assert Repo.reload!(ctx.conv).status == ctx.conv.status

      assert {:error, {:chatgpt_grant_unusable, %{reason: :exhausted, until: ^reset}}} =
               TurnMachine.gate(ctx.user.id, ctx.source)

      assert {:error,
              {:chatgpt_grant_unusable, %{grant_id: ^main_id, reason: :exhausted, until: ^reset}}} =
               TurnMachine.open(ctx.conv.id, ctx.sandbox.id, "hi", ctx.agent, nil, ctx.source)

      assert [%{data: data}] = admission_refusals(ctx.conv)

      assert %{
               "event" => "admission_refused",
               "reason" => "chatgpt_grant_unusable",
               "grant_reason" => "exhausted",
               "grant_id" => ^main_id,
               "until" => until
             } = Jason.decode!(data)

      assert until == DateTime.to_iso8601(reset)

      assert %{until: ^reset, grant_reason: "exhausted", retryable: false} =
               Fountain.Conversations.CodexChatGPT.refusal_stage(
                 {:chatgpt_grant_unusable,
                  %{grant_id: main_id, name: "Main", reason: :exhausted, until: reset}},
                 ctx.user.id,
                 ctx.source
               )

      # Naming the other subscription is the owner's to do, and it runs.
      # The fixtures' machines are at the account's sandbox cap; end them.
      Repo.update_all(from(s in Sandbox, where: s.user_id == ^ctx.user.id),
        set: [status: "destroyed"]
      )

      assert {:ok, conv} =
               launch(ctx, %{
                 "sandbox_mode" => "ephemeral",
                 "inference_credential_id" => ctx.on_spare.id
               })

      assert %{"scope" => "grant", "grant_id" => spare_id} = conv.inference_source
      assert spare_id == ctx.spare.id
    end

    test "once the reset passes the same conversation is admitted, and nothing was written",
         ctx do
      past = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)

      Repo.update_all(from(a in Fountain.PlatformChatGPT.Account, where: a.id == ^ctx.main.id),
        set: [usage_exhausted_until: past]
      )

      before = grant_row(ctx.main)
      assert :ok = InferenceCredentials.validate_source(ctx.user.id, ctx.source)
      assert :ok = TurnMachine.gate(ctx.user.id, ctx.source)

      assert {:ok, _conv, %{status: "running"} = turn} =
               TurnMachine.open(ctx.conv.id, ctx.sandbox.id, "hi", ctx.agent, nil, ctx.source)

      assert turn.inference_source == Source.dump(ctx.source)
      assert admission_refusals(ctx.conv) == []
      assert grant_row(ctx.main) == before
    end

    @tag :capture_log
    test "no check starts for a key, for a grant turn failing otherwise, or with no owner", ctx do
      stub_usage(limited(~U[2099-01-01 00:00:00Z]))
      owner = %{user_id: ctx.user.id}
      %Source{} = source = ctx.source

      for machine_ctx <- [
            Map.put(owner, :inference, %Source{
              scope: :credential,
              kind: :openai_api_key,
              identity: "credential:x:openai"
            }),
            Map.put(owner, :inference, %{source | scope: :tenant_secret}),
            Map.put(owner, :inference, %{source | kind: :openai_api_key}),
            Map.put(owner, :inference, nil),
            %{inference: ctx.source},
            %{inference: ctx.source, user_id: nil}
          ] do
        assert {_turn, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
                 fail_turn(ctx, @usage_limit_error, machine_ctx)
      end

      fail_turn(
        ctx,
        %{"code" => -32_603, "message" => "boom"},
        Map.put(owner, :inference, ctx.source)
      )

      # Somebody else's turn naming this grant asks nothing either.
      stranger = insert_active_user()
      fail_turn(ctx, @usage_limit_error, %{inference: ctx.source, user_id: stranger.id})

      refute_received :usage_checked
      assert %{usage_exhausted_until: nil, usage_checked_at: nil} = grant_row(ctx.main)
    end
  end

  # Reachable since stage 3 lets a conversation run on a grant:
  # `validate_source/2` keeps the refusal whole, and the stream used to flatten
  # any non-atom refusal to "invalid_turn".
  test "a turn refused because its subscription is unusable says so on the stream", ctx do
    {:ok, %Source{scope: :grant} = source, _} =
      InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, "codex",
        credential_set_id: ctx.set.id
      )

    sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

    conv =
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox_id: sandbox.id,
        runtime: "codex"
      )

    conv
    |> Ecto.Changeset.change(inference_source: Source.dump(source))
    |> Repo.update!()

    :ok = ChatGPTAccounts.disconnect_for_user(ctx.grant.id, ctx.user.id)

    assert {:error, {:chatgpt_grant_unusable, %{reason: :disconnected} = detail}} =
             Fountain.Conversations.TurnMachine.open(
               conv.id,
               sandbox.id,
               "hi",
               ctx.agent,
               nil,
               source
             )

    events =
      Repo.all(
        from e in Fountain.Conversations.LogEvent,
          where: e.conversation_id == ^conv.id and e.kind == "stage" and e.stage == "sandbox",
          order_by: e.id
      )

    assert [%{state: "done", data: data}] = events

    assert %{
             "event" => "admission_refused",
             "reason" => "chatgpt_grant_unusable",
             "grant_reason" => "disconnected",
             "grant_id" => grant_id,
             "message" => message
           } = Jason.decode!(data)

    assert grant_id == ctx.grant.id
    assert message == InferenceCredentials.grant_unusable_message(detail)
    assert message =~ ~s("Work" is disconnected)
  end
end
