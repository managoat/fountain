defmodule Fountain.ChatGPTUserExhaustionTest do
  @moduledoc """
  A user's own ChatGPT subscription at its usage limit (ADR 0060 decision 4),
  beside `Fountain.PlatformChatGPTExhaustionTest` and by the same rule: a
  sandbox's `usageLimitExceeded` is only a hint, the server asks the ChatGPT
  backend's `/wham/usage` with that grant's token, and only a confirmed limit
  is recorded, on that grant's row and no other.

  What differs is the owner, which is in every query: another user's grant, a
  generation since replaced, a tombstone and a suspended owner's grant are
  ignored with no call. Nothing is substituted for an exhausted grant.

  `async: false`: the shared `Req.Test` stub, the broker in the application
  environment, and the platform row.
  """

  use Fountain.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Fountain.ChatGPTFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Accounts.User
  alias Fountain.Audit.{AdminEvent, Event}
  alias Fountain.ChatGPTAccounts
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.Account

  @usage_path "/backend-api/wham/usage"
  @model "openai/gpt-5.5-codex"
  @now ~U[2026-09-16 20:00:00Z]
  @reset ~U[2026-09-20 11:40:00Z]
  @tenant_lock "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))"

  setup do
    previous =
      for key <- [:broker_listen_port, :broker_proxy_url],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    # A named grant resolves only on a brokered deployment.
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    stub_auth(%{})
    :ok
  end

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
        "secondary_window" => %{
          "used_percent" => 100,
          "limit_window_seconds" => 604_800,
          "reset_at" => DateTime.to_unix(reset)
        }
      },
      "credits" => %{"has_credits" => false, "unlimited" => false}
    }
  end

  defp not_limited_body do
    %{
      "plan_type" => "pro",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false},
      "credits" => %{"has_credits" => false, "unlimited" => false}
    }
  end

  defp source(%Account{} = grant) do
    %{
      Source.grant()
      | kind: :codex_chatgpt_access_token,
        grant_id: grant.id,
        generation: grant.generation
    }
  end

  defp events(user) do
    Repo.all(
      from e in Event,
        where: e.user_id == ^user.id and e.action == "chatgpt_grant.exhausted",
        order_by: e.id
    )
  end

  # A set naming `grant`, and what a codex run on it resolves to.
  defp set_naming(user, grant, name) do
    {:ok, set} = InferenceCredentials.create_set(user.id, name)
    {:ok, set} = InferenceCredentials.set_grant(set, grant.id)
    set
  end

  defp resolve(user, set),
    do: InferenceCredentials.resolve(user.id, @model, "codex", credential_set_id: set.id)

  defp soon, do: DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.truncate(:second)

  describe "confirm_exhausted_for_user/3" do
    test "records the backend's reset on that grant alone, with the trail and no secret" do
      user = insert_verified_user()
      access = access_token()
      work = user_grant!(user.id, %{name: "Work", access_token: access, refresh_token: "rt_work"})
      side = user_grant!(user.id, %{name: "Side"})
      platform = connect!()
      work_set = set_naming(user, work, "On work")
      side_set = set_naming(user, side, "On side")
      :ok = ChatGPTAccounts.subscribe(user.id)
      reset = soon()
      stub_usage(limited_body(reset))

      assert :recorded = ChatGPTAccounts.confirm_exhausted_for_user(source(work), user.id)
      assert_received :usage_checked
      user_id = user.id
      assert_received {:chatgpt_grants_changed, ^user_id}

      assert %Account{usage_exhausted_until: ^reset, status: "active", generation: generation} =
               Repo.get!(Account, work.id)

      assert generation == work.generation

      assert %Account{usage_exhausted_until: nil, usage_checked_at: nil} =
               Repo.get!(Account, side.id)

      assert %Account{usage_exhausted_until: nil, usage_checked_at: nil} =
               Repo.get!(Account, platform.id)

      assert ChatGPTAccounts.platform_exhausted_until() == nil

      work_id = work.id

      assert {:error,
              {:chatgpt_grant_unusable,
               %{grant_id: ^work_id, name: "Work", reason: :exhausted, until: ^reset}}} =
               resolve(user, work_set)

      assert {:ok, %Source{scope: :grant, grant_id: side_id}, _} = resolve(user, side_set)
      assert side_id == side.id
      assert {:ok, %{exhausted_until: ^reset}} = ChatGPTAccounts.get_for_user(work.id, user.id)

      assert [event] = events(user)
      assert event.actor == "system:chatgpt_accounts"
      assert event.resource_type == "chatgpt_grant"
      assert event.resource_id == work.id

      assert event.metadata == %{
               "name" => "Work",
               "until" => DateTime.to_iso8601(reset),
               "confirmed_by" => "wham/usage"
             }

      for secret <- [access, "rt_work", work.account_id, work.generation] do
        refute inspect(event) =~ secret
      end

      assert Repo.all(from e in AdminEvent, where: like(e.event_type, "%exhausted")) == []
    end

    test "a hint the backend does not confirm, a failed call or an unreadable body writes nothing" do
      user = insert_verified_user()
      grant = user_grant!(user.id)

      for {body, status, expected} <- [
            {not_limited_body(), 200, :not_limited},
            {%{"error" => "nope"}, 401, {:error, {:usage, 401}}},
            {%{"unexpected" => true}, 200, {:error, :unexpected_usage_body}}
          ] do
        Repo.update_all(Account, set: [usage_checked_at: nil])
        stub_usage(body, status)

        assert ^expected =
                 ChatGPTAccounts.confirm_exhausted_for_user(source(grant), user.id, @now)

        assert_received :usage_checked
      end

      assert %Account{usage_exhausted_until: nil, usage_exhausted_at: nil} =
               Repo.get!(Account, grant.id)

      assert events(user) == []
    end

    test "sends that grant's token and account id, and only to the usage endpoint" do
      user = insert_verified_user()
      access = access_token()
      grant = user_grant!(user.id, %{access_token: access, account_id: "acct_mine"})
      _other = user_grant!(user.id, %{access_token: access_token(3_600, %{"n" => 2})})
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

      assert :not_limited =
               ChatGPTAccounts.confirm_exhausted_for_user(source(grant), user.id, @now)

      bearer = "Bearer " <> access
      assert_received {:request, "GET", @usage_path, [^bearer], ["acct_mine"]}
      refute_received {:request, _, _, _, _}
    end

    test "one check per cooldown and per grant, however many hints arrive" do
      user = insert_verified_user()
      grant = user_grant!(user.id)
      other = user_grant!(user.id)
      stub_usage(not_limited_body())

      assert :not_limited =
               ChatGPTAccounts.confirm_exhausted_for_user(source(grant), user.id, @now)

      assert_received :usage_checked

      for _ <- 1..5 do
        assert :throttled =
                 ChatGPTAccounts.confirm_exhausted_for_user(source(grant), user.id, @now)
      end

      refute_received :usage_checked

      # The cooldown is the grant's own: the user's other one is still askable.
      assert :not_limited =
               ChatGPTAccounts.confirm_exhausted_for_user(source(other), user.id, @now)

      assert_received :usage_checked

      later = DateTime.add(@now, ChatGPTAccounts.platform_usage_check_cooldown_seconds(), :second)

      assert :not_limited =
               ChatGPTAccounts.confirm_exhausted_for_user(source(grant), user.id, later)

      assert_received :usage_checked
    end

    test "concurrent hints make one call" do
      user = insert_verified_user()
      grant = user_grant!(user.id)
      stub_usage(not_limited_body())

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            ChatGPTAccounts.confirm_exhausted_for_user(source(grant), user.id, @now)
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &(&1 == :not_limited)) == 1
      assert Enum.count(results, &(&1 == :throttled)) == 7
    end

    test "an exhaustion already recorded is not checked again, and reads as nil once it passes" do
      user = insert_verified_user()
      grant = user_grant!(user.id)
      set = set_naming(user, grant, "On it")
      Repo.update_all(Account, set: [usage_exhausted_until: @reset])
      stub_usage(limited_body())

      assert :already = ChatGPTAccounts.confirm_exhausted_for_user(source(grant), user.id, @now)
      refute_received :usage_checked

      # 2026-09-20 is behind the wall clock: no write clears it, and the
      # grant resolves again.
      assert {:ok, %{exhausted_until: nil}} = ChatGPTAccounts.get_for_user(grant.id, user.id)
      assert {:ok, %Source{scope: :grant}, _} = resolve(user, set)
      assert %Account{usage_exhausted_until: @reset} = Repo.get!(Account, grant.id)
    end

    test "another owner, a replaced generation, a tombstone, a suspended owner and any other source are ignored" do
      user = insert_verified_user()
      stranger = insert_verified_user()
      grant = user_grant!(user.id, %{account_id: "acct_one"})
      platform = connect!()
      stub_usage(limited_body())

      platform_source = %Source{
        scope: :platform,
        kind: :codex_chatgpt_access_token,
        identity: "platform:chatgpt:" <> platform.id,
        revision: platform.generation
      }

      for {src, owner} <- [
            {source(grant), stranger.id},
            {source(grant), nil},
            {source(grant), "not-a-uuid"},
            {%Source{source(grant) | generation: Ecto.UUID.generate()}, user.id},
            {%Source{source(grant) | kind: :openai_api_key}, user.id},
            {%Source{source(grant) | scope: :credential}, user.id},
            {%Source{source(grant) | grant_id: platform.id, generation: platform.generation},
             user.id},
            {platform_source, user.id},
            {nil, user.id}
          ] do
        assert :ignored = ChatGPTAccounts.confirm_exhausted_for_user(src, owner, @now)

        # The background door starts nothing for a source that is not a
        # grant's or an owner that is no id, and what it does start is ignored.
        started = ChatGPTAccounts.check_exhaustion_for_user(src, owner) |> settle()
        assert started in [:started, :ignored]

        unless match?(%Source{scope: :grant, kind: :codex_chatgpt_access_token}, src) and
                 match?({:ok, _}, Ecto.UUID.cast(owner || "")),
               do: assert(started == :ignored)
      end

      # A sign-in since: the turn's generation is not the row's any more.
      {:ok, _} = ChatGPTAccounts.reconnect_for_user(grant.id, user.id, user_tokens("acct_one"))
      assert :ignored = ChatGPTAccounts.confirm_exhausted_for_user(source(grant), user.id, @now)

      tombstone = user_grant!(user.id)
      :ok = ChatGPTAccounts.disconnect_for_user(tombstone.id, user.id)

      assert :ignored =
               ChatGPTAccounts.confirm_exhausted_for_user(source(tombstone), user.id, @now)

      suspended = insert_verified_user()
      theirs = user_grant!(suspended.id)
      Repo.update_all(from(u in User, where: u.id == ^suspended.id), set: [suspended_at: @now])

      assert :ignored =
               ChatGPTAccounts.confirm_exhausted_for_user(source(theirs), suspended.id, @now)

      refute_received :usage_checked
      assert Repo.all(from a in Account, where: not is_nil(a.usage_checked_at)) == []
      assert Repo.all(from a in Account, where: not is_nil(a.usage_exhausted_until)) == []
      assert events(user) == [] and events(suspended) == []
    end

    test "a platform source never reaches a user's row, nor a user's source the platform's" do
      user = insert_verified_user()
      grant = user_grant!(user.id)
      connect!()
      stub_usage(limited_body())

      assert :ignored = ChatGPTAccounts.platform_confirm_exhausted(source(grant), @now)
      assert :ignored = ChatGPTAccounts.platform_check_exhaustion(source(grant))
      refute_received :usage_checked
    end
  end

  describe "check_exhaustion_for_user/2" do
    test "checks in the background and records what the backend confirms" do
      user = insert_verified_user()
      grant = user_grant!(user.id)
      reset = soon()
      stub_usage(limited_body(reset))

      assert :started = ChatGPTAccounts.check_exhaustion_for_user(source(grant), user.id)
      Fountain.DataCase.drain_best_effort_tasks(self())

      assert_received :usage_checked
      assert %Account{usage_exhausted_until: ^reset} = Repo.get!(Account, grant.id)
    end
  end

  # ADR 0060 decision 5, in `chatgpt_grant_source_lock_test.exs`'s idiom: two
  # sessions have to contend, so every actor is an unboxed connection and the
  # users are really committed and deleted in `after`.
  describe "the source lock" do
    test "one user's usage check takes that user's key and parks nobody else's resolve" do
      with_users(2, fn [owner, bystander] ->
        grant = user_grant!(owner.id)
        stub_usage(limited_body(soon()))

        writer =
          paused_after_tenant_lock(fn ->
            ChatGPTAccounts.confirm_exhausted_for_user(source(grant), owner.id)
          end)

        try do
          assert_receive {:locked, writer_pid}, 5_000
          assert writer_pid == writer.pid

          # The platform key is not held either: a resolve takes it shared.
          assert {:ok, %Source{}, _credentials} =
                   Task.await(independent(fn -> resolve_default(bystander.id) end), 5_000)

          assert Task.yield(writer, 0) == nil

          own = independent(fn -> resolve_default(owner.id) end)
          own_pid = own.pid
          assert_receive {:backend, ^own_pid, backend}, 5_000
          await_blocked(backend)

          send(writer.pid, :continue)
          assert :recorded = Task.await(writer, 5_000)
          assert {:ok, %Source{}, _credentials} = Task.await(own, 5_000)
        after
          Task.shutdown(writer, :brutal_kill)
        end
      end)
    end

    test "no lock is held while OpenAI is asked" do
      with_users(1, fn [owner] ->
        grant = user_grant!(owner.id)
        test = self()

        stub_auth(%{
          @usage_path => fn _ ->
            send(test, {:asking, self()})

            receive do
              :answer -> {200, limited_body(soon())}
            after
              10_000 -> raise "the usage call was not released"
            end
          end
        })

        checker =
          independent(fn ->
            ChatGPTAccounts.confirm_exhausted_for_user(source(grant), owner.id)
          end)

        try do
          assert_receive {:asking, stub_pid}, 5_000

          # The owner's own resolve goes through while the call is open.
          assert {:ok, %Source{}, _credentials} =
                   Task.await(independent(fn -> resolve_default(owner.id) end), 5_000)

          send(stub_pid, :answer)
          assert :recorded = Task.await(checker, 5_000)
        after
          Task.shutdown(checker, :brutal_kill)
        end
      end)
    end
  end

  # `check_exhaustion_for_user/2` answers at once; wait out anything it started.
  defp settle(result) do
    Fountain.DataCase.drain_best_effort_tasks(self())
    result
  end

  defp resolve_default(user_id), do: InferenceCredentials.resolve(user_id, @model, "codex")

  defp paused_after_tenant_lock(fun) do
    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler_id, [:fountain, :repo, :query], &__MODULE__.pause/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    independent(fn ->
      Process.put(:pause_after_tenant_lock, true)
      fun.()
    end)
  end

  @doc false
  def pause(_event, _measurements, metadata, owner) do
    if Process.get(:pause_after_tenant_lock) && metadata.query == @tenant_lock do
      Process.delete(:pause_after_tenant_lock)
      send(owner, {:locked, self()})

      receive do
        :continue -> :ok
      after
        10_000 -> raise "the paused write was not released"
      end
    end
  end

  defp with_users(count, fun) do
    Sandbox.unboxed_run(Repo, fn ->
      # Verified by hand, as in the source-lock test: `verify_email/1` commits
      # rows this test does not want to clean up.
      users =
        for _ <- 1..count do
          user =
            insert_user() |> change(email_verified_at: ~U[2026-09-01 00:00:00Z]) |> Repo.update!()

          {:ok, _dek} = Crypto.load_tenant_key(user.id)
          user
        end

      try do
        fun.(users)
      after
        ids = Enum.map(users, & &1.id)
        Repo.delete_all(from e in Event, where: e.user_id in ^ids)
        Repo.delete_all(from u in User, where: u.id in ^ids)
      end
    end)
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "the competing operation did not wait on the source lock"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
