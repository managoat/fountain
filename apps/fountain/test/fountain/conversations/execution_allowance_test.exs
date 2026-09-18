defmodule Fountain.Conversations.ExecutionAllowanceTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.ExecutionAllowance, as: Allowance

  setup do
    %{conversation: insert_conversation()}
  end

  test "persists canonical limits and a revision across reloads", %{conversation: conversation} do
    allowance = insert_allowance(conversation.id)
    assert Repo.reload!(allowance) == allowance
    assert allowance.limits == %{"max_model_turns" => 10, "wall_time_seconds" => 60}
    assert {:ok, _} = Ecto.UUID.cast(allowance.revision)
  end

  test "a duplicate insert cannot replace a saved allowance", %{conversation: conversation} do
    allowance = insert_allowance(conversation.id)

    assert {:error, changeset} =
             conversation.id |> Allowance.new_changeset(nil) |> Repo.insert()

    assert errors_on(changeset).conversation_id == ["has already been taken"]
    assert Repo.reload!(allowance) == allowance
  end

  test "requires an existing conversation" do
    assert {:error, changeset} =
             Ecto.UUID.generate() |> Allowance.new_changeset(%{}) |> Repo.insert()

    assert errors_on(changeset).conversation_id == ["does not exist"]
  end

  test "malformed limits cannot be saved", %{conversation: conversation} do
    for limits <- [%{max_model_turns: 0}, %{wall_time_seconds: nil}, %{revision: "override"}] do
      assert {:error, changeset} =
               conversation.id |> Allowance.new_changeset(limits) |> Repo.insert()

      assert errors_on(changeset).limits != []
    end

    assert Repo.get(Allowance, conversation.id) == nil
  end

  test "partial narrowing retains omitted fields and advances the revision", %{
    conversation: conversation
  } do
    allowance = insert_allowance(conversation.id)

    updated =
      allowance |> Allowance.narrow_changeset(%{max_model_turns: 3}) |> Repo.update!()

    assert updated.limits == %{"max_model_turns" => 3, "wall_time_seconds" => 60}
    refute updated.revision == allowance.revision

    for request <- [nil, %{}] do
      updated = Repo.reload!(updated) |> Allowance.narrow_changeset(request) |> Repo.update!()
      assert updated.limits == %{"max_model_turns" => 3, "wall_time_seconds" => 60}
    end
  end

  test "widening or clearing a field is refused", %{conversation: conversation} do
    allowance = insert_allowance(conversation.id)

    for request <- [%{max_model_turns: 11}, %{wall_time_seconds: nil}] do
      assert {:error, changeset} =
               allowance |> Allowance.narrow_changeset(request) |> Repo.update()

      assert errors_on(changeset).limits != []
      assert Repo.reload!(allowance) == allowance
    end
  end

  test "narrowing cannot replace a saved JSON null with an unrestricted or fresh allowance", %{
    conversation: conversation
  } do
    allowance = insert_allowance(conversation.id)

    Repo.query!(
      "UPDATE execution_allowances SET limits = 'null'::jsonb WHERE conversation_id = $1",
      [Ecto.UUID.dump!(conversation.id)]
    )

    corrupt = Repo.reload!(allowance)
    assert corrupt.limits == nil

    for request <- [nil, %{}, %{max_model_turns: 2}] do
      assert {:error, changeset} = corrupt |> Allowance.narrow_changeset(request) |> Repo.update()
      assert errors_on(changeset).limits == ["execution_limits_invalid: object_required"]
      assert Repo.reload!(corrupt) == corrupt
    end
  end

  test "narrowing preserves malformed saved maps and does not expose their contents", %{
    conversation: conversation
  } do
    corrupt =
      insert_allowance(conversation.id)
      |> Ecto.Changeset.change(limits: %{"private-field" => "private-value"})
      |> Repo.update!()

    for request <- [nil, %{}, %{max_model_turns: 2}] do
      assert {:error, changeset} = corrupt |> Allowance.narrow_changeset(request) |> Repo.update()
      assert errors_on(changeset).limits == ["execution_limits_invalid: unknown_field"]
      assert Repo.reload!(corrupt) == corrupt
    end
  end

  test "an explicitly empty saved allowance can still be narrowed", %{conversation: conversation} do
    allowance = conversation.id |> Allowance.new_changeset(%{}) |> Repo.insert!()
    updated = allowance |> Allowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update!()

    assert updated.limits == %{"max_model_turns" => 2}
    refute updated.revision == allowance.revision
  end

  test "stale narrowing cannot overwrite a tighter stored value", %{conversation: conversation} do
    stale = insert_allowance(conversation.id)
    winner = stale |> Allowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update!()

    assert_raise Ecto.StaleEntryError, fn ->
      stale |> Allowance.narrow_changeset(%{max_model_turns: 5}) |> Repo.update!()
    end

    assert Repo.reload!(stale) == winner
  end

  test "stale omission cannot restore another field's old allowance", %{
    conversation: conversation
  } do
    stale = insert_allowance(conversation.id)
    winner = stale |> Allowance.narrow_changeset(%{wall_time_seconds: 10}) |> Repo.update!()

    assert {:error, changeset} =
             stale
             |> Allowance.narrow_changeset(%{max_model_turns: 2})
             |> Repo.update(stale_error_field: :revision)

    assert errors_on(changeset).revision == ["is stale"]
    assert Repo.reload!(stale) == winner

    revalidated =
      Repo.reload!(stale) |> Allowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update!()

    assert revalidated.limits == %{"max_model_turns" => 2, "wall_time_seconds" => 10}
  end

  test "ordinary conversation updates cannot touch the separate allowance", %{
    conversation: conversation
  } do
    allowance = insert_allowance(conversation.id)

    assert {:ok, _} =
             Fountain.Conversations.update_conversation(conversation, %{title: "renamed"})

    assert Repo.reload!(allowance) == allowance
  end

  test "conversation deletion removes only its own allowance", %{conversation: conversation} do
    allowance = insert_allowance(conversation.id)
    other = insert_conversation() |> Map.fetch!(:id) |> insert_allowance()
    Repo.delete!(conversation)
    assert Repo.get(Allowance, allowance.conversation_id) == nil
    assert Repo.reload!(other) == other
  end

  test "scoped narrowing hides foreign and missing records before validating requests", %{
    conversation: conv
  } do
    allowance = insert_allowance(conv.id)
    other = insert_conversation()

    for request <- [%{max_model_turns: 2}, %{"private-field" => "private-value"}] do
      for {id, user_id} <- [
            {conv.id, other.user_id},
            {Ecto.UUID.generate(), conv.user_id},
            {other.id, other.user_id}
          ] do
        assert Conversations.narrow_execution_allowance(id, user_id, request) ==
                 {:error, :not_found}
      end
    end

    assert Repo.reload!(allowance) == allowance
    assert Repo.get(Allowance, other.id) == nil
    assert allowance_events(conv) == []
  end

  test "scoped narrowing retains omitted fields without touching active work", %{
    conversation: conv
  } do
    before = Repo.reload!(conv)
    allowance = insert_allowance(conv.id)
    turn = insert_turn(conv, status: "running")
    sandbox = Repo.reload!(conv.sandbox)
    other = insert_conversation() |> Map.fetch!(:id) |> insert_allowance()

    assert {:ok, narrowed} =
             Conversations.narrow_execution_allowance(
               conv.id,
               conv.user_id,
               %{max_model_turns: 2},
               actor: "api",
               request_ip: "192.0.2.1"
             )

    assert narrowed.limits == %{"max_model_turns" => 2, "wall_time_seconds" => 60}
    refute narrowed.revision == allowance.revision

    for request <- [nil, %{}] do
      assert {:ok, updated} =
               Conversations.narrow_execution_allowance(conv.id, conv.user_id, request)

      assert updated == narrowed
    end

    assert Repo.reload!(conv) == before
    assert Repo.reload!(turn) == turn
    assert Repo.reload!(sandbox) == sandbox
    assert Repo.reload!(other) == other
    assert [event] = allowance_events(conv)
    assert event.user_id == conv.user_id
    assert event.actor == "api"
    assert event.request_ip == "192.0.2.1"
    assert event.metadata == %{"changed" => ["max_model_turns"]}
  end

  test "scoped narrowing rejects wider, cleared and malformed requests", %{conversation: conv} do
    allowance = insert_allowance(conv.id)

    for request <- [%{max_model_turns: 11}, %{wall_time_seconds: nil}, %{unknown: 2}] do
      assert {:error, changeset} =
               Conversations.narrow_execution_allowance(conv.id, conv.user_id, request)

      assert errors_on(changeset).limits != []
      assert Repo.reload!(allowance) == allowance
    end

    assert allowance_events(conv) == []
  end

  test "scoped narrowing cannot erase corrupt saved policy", %{conversation: conv} do
    allowance = insert_allowance(conv.id)

    Repo.query!(
      "UPDATE execution_allowances SET limits = 'null'::jsonb WHERE conversation_id = $1",
      [Ecto.UUID.dump!(conv.id)]
    )

    corrupt = Repo.reload!(allowance)

    for request <- [nil, %{}, %{max_model_turns: 2}] do
      assert Conversations.narrow_execution_allowance(conv.id, conv.user_id, request) ==
               {:error, {:execution_limits_invalid, "object_required"}}

      assert Repo.reload!(corrupt) == corrupt
    end

    assert allowance_events(conv) == []
  end

  test "narrowing an empty policy does not admit an unsupported turn", %{conversation: conv} do
    conv.id |> Allowance.new_changeset(%{}) |> Repo.insert!()

    assert {:ok, allowance} =
             Conversations.narrow_execution_allowance(conv.id, conv.user_id, %{max_model_turns: 2})

    assert {:error, {:execution_limits_unsupported, ["max_model_turns"]}} =
             Fountain.Conversations.TurnMachine.open(conv.id, conv.sandbox_id, "refused")

    assert Repo.reload!(allowance).limits == %{"max_model_turns" => 2}
    assert Conversations._unsafe_list_turns(conv.id) == []
    refute Repo.exists?(from e in Fountain.Billing.UsageEvent, where: e.user_id == ^conv.user_id)
  end

  test "scoped creation hides foreign and missing conversations before validation", %{
    conversation: conv
  } do
    other = insert_conversation()

    for limits <- [%{}, %{"private-field" => "private-value"}],
        {id, user_id} <- [{conv.id, other.user_id}, {Ecto.UUID.generate(), conv.user_id}] do
      assert Conversations.create_execution_allowance(id, user_id, limits) == {:error, :not_found}
    end

    assert Repo.get(Allowance, conv.id) == nil
    assert Repo.get(Allowance, other.id) == nil
    assert creation_events(conv) == []
  end

  test "scoped creation records only control names and leaves active work unchanged", %{
    conversation: conv
  } do
    before = Repo.reload!(conv)
    turn = insert_turn(conv, status: "running")
    sandbox = Repo.reload!(conv.sandbox)
    other = insert_conversation() |> Map.fetch!(:id) |> insert_allowance()

    assert {:ok, allowance} =
             Conversations.create_execution_allowance(
               conv.id,
               conv.user_id,
               %{max_model_turns: 2, wall_time_seconds: 30, max_estimated_cost_usd: 0.25},
               actor: "api",
               request_ip: "192.0.2.1"
             )

    assert allowance.limits == %{
             "max_model_turns" => 2,
             "wall_time_seconds" => 30,
             "max_estimated_cost_usd" => 0.25
           }

    assert Repo.reload!(allowance) == allowance
    assert Repo.reload!(conv) == before
    assert Repo.reload!(turn) == turn
    assert Repo.reload!(sandbox) == sandbox
    assert Repo.reload!(other) == other
    assert [event] = creation_events(conv)
    assert event.user_id == conv.user_id
    assert event.actor == "api"
    assert event.request_ip == "192.0.2.1"

    assert event.metadata == %{
             "controls" => ["wall_time_seconds", "max_model_turns", "max_estimated_cost_usd"]
           }
  end

  test "scoped creation cannot replace an existing policy even with omission", %{
    conversation: conv
  } do
    allowance = insert_allowance(conv.id)

    for limits <- [nil, %{}, %{max_model_turns: 1}, %{max_model_turns: 20}] do
      assert {:error, changeset} =
               Conversations.create_execution_allowance(conv.id, conv.user_id, limits)

      assert errors_on(changeset).conversation_id == ["has already been taken"]
      assert Repo.reload!(allowance) == allowance
    end

    assert creation_events(conv) == []
  end

  test "scoped creation refuses invalid controls without a row or audit", %{conversation: conv} do
    for limits <- [
          %{"private-field" => "private-value"},
          %{max_model_turns: 0},
          %{wall_time_seconds: nil}
        ] do
      assert {:error, changeset} =
               Conversations.create_execution_allowance(conv.id, conv.user_id, limits)

      errors = Jason.encode!(errors_on(changeset))
      refute errors =~ "private-field"
      refute errors =~ "private-value"
      assert errors_on(changeset).limits != []
    end

    assert Repo.get(Allowance, conv.id) == nil
    assert creation_events(conv) == []
  end

  test "a saved initial allowance does not grant unsupported execution", %{conversation: conv} do
    assert {:ok, allowance} =
             Conversations.create_execution_allowance(conv.id, conv.user_id, %{max_model_turns: 2})

    assert {:error, {:execution_limits_unsupported, ["max_model_turns"]}} =
             Fountain.Conversations.TurnMachine.open(conv.id, conv.sandbox_id, "refused")

    assert Repo.reload!(allowance).limits == %{"max_model_turns" => 2}
    assert Conversations._unsafe_list_turns(conv.id) == []
    refute Repo.exists?(from e in Fountain.Billing.UsageEvent, where: e.user_id == ^conv.user_id)
  end

  defp creation_events(conv),
    do:
      Repo.all(
        from e in Fountain.Audit.Event,
          where:
            e.resource_id == ^conv.id and e.action == "conversation.execution_allowance_created"
      )

  defp allowance_events(conv),
    do:
      Repo.all(
        from e in Fountain.Audit.Event,
          where:
            e.resource_id == ^conv.id and e.action == "conversation.execution_allowance_narrowed"
      )

  defp insert_allowance(conversation_id) do
    conversation_id
    |> Allowance.new_changeset(%{max_model_turns: 10, wall_time_seconds: 60})
    |> Repo.insert!()
  end
end

defmodule Fountain.Conversations.ExecutionAllowanceRaceTest do
  use ExUnit.Case, async: false

  alias Fountain.Repo
  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Conversations.ExecutionAllowance, as: Allowance
  alias Fountain.Conversations.Launch
  import Fountain.DataCase, only: [errors_on: 1]
  import Fountain.Factory, only: [insert_conversation: 1]
  import Ecto.Query, only: [from: 2]

  test "a writer blocked on another connection cannot restore a wider allowance" do
    race(:stale)
  end

  test "a scoped writer revalidates widening after a concurrent narrowing commits" do
    race(:widen)
  end

  test "concurrent scoped writers retain each other's tighter fields" do
    race(:disjoint)
  end

  for mode <- [:duplicate, :ownership] do
    test "initial creation rechecks #{mode} after a PostgreSQL lock wait" do
      creation_race(unquote(mode))
    end
  end

  defp creation_race(mode) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      users =
        for _ <- 1..2,
            do:
              Repo.insert!(%Fountain.Accounts.User{
                email: "initial-allowance-race-#{Ecto.UUID.generate()}@example.test"
              })

      [user, other] = users
      conv = insert_conversation(user_id: user.id)
      owner = self()

      winner =
        independent_writer(fn ->
          Repo.transaction(fn ->
            value =
              case mode do
                :duplicate -> insert_allowance(conv.id)
                :ownership -> conv |> Ecto.Changeset.change(user_id: other.id) |> Repo.update!()
              end

            send(owner, :changed)

            receive do
              :commit -> value
            after
              5_000 -> raise "commit barrier timed out"
            end
          end)
        end)

      try do
        assert_receive :changed, 5_000

        loser =
          independent_writer(fn ->
            Conversations.create_execution_allowance(conv.id, user.id, %{})
          end)

        try do
          assert_receive {:backend, winner_pid, winner_backend}, 5_000
          assert winner_pid == winner.pid
          assert_receive {:backend, loser_pid, loser_backend}, 5_000
          assert loser_pid == loser.pid
          refute winner_backend == loser_backend
          await_blocked(loser_backend, System.monotonic_time(:millisecond) + 5_000)
          send(winner.pid, :commit)
          assert {:ok, saved} = Task.await(winner)

          case {mode, Task.await(loser)} do
            {:duplicate, {:error, changeset}} ->
              assert errors_on(changeset).conversation_id == ["has already been taken"]
              assert Repo.get!(Allowance, conv.id) == saved

            {:ownership, {:error, :not_found}} ->
              assert Repo.reload!(conv).user_id == other.id
              assert Repo.get(Allowance, conv.id) == nil
          end

          refute Repo.exists?(
                   from e in Fountain.Audit.Event,
                     where:
                       e.resource_id == ^conv.id and
                         e.action == "conversation.execution_allowance_created"
                 )
        after
          Task.shutdown(loser, :brutal_kill)
        end
      after
        Task.shutdown(winner, :brutal_kill)
        for user <- users, do: Repo.delete!(user)
        Repo.get!(Sandbox, conv.sandbox_id) |> Repo.delete!()
        assert Repo.get(Allowance, conv.id) == nil
      end
    end)
  end

  # The account ceiling is re-resolved inside the admission transaction, so a
  # change another connection commits after the early preflight still refuses.
  # Both `users` and `agents` are read unlocked on purpose — inside
  # `with_sandbox_reservation/3` a row lock would be held under the global
  # fleet lock — so this asserts the recheck reads current committed state,
  # not a lock ordering.
  for path <- [:attach, :fresh] do
    test "#{path} honours a ceiling committed after its preflight" do
      admission_race(unquote(path))
    end
  end

  defp admission_race(path) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user =
        Repo.insert!(%Fountain.Accounts.User{
          email: "attach-policy-race-#{Ecto.UUID.generate()}@example.test",
          credit_balance_cents: 500
        })

      Repo.insert!(%Fountain.Accounts.UserDataKey{
        user_id: user.id,
        wrapped_key: Fountain.Crypto.wrap_dek(Fountain.Crypto.generate_dek())
      })

      env = Fountain.Factory.insert_env(user_id: user.id)

      agent =
        Fountain.Factory.insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

      sandbox =
        Fountain.Factory.insert_sandbox(
          user_id: user.id,
          agent_id: agent.id,
          environment_id: env.id,
          status: "ready"
        )

      owner = self()

      try do
        admitting =
          independent_writer(fn ->
            Fountain.ServerStart.stub_server_start(fn _, _ ->
              send(owner, :unexpected_worker_started)
              {:error, :fixture_rejection}
            end)

            # Runs immediately after the early preflight read the ceiling and
            # allowed the launch. Hold here until the new ceiling is committed.
            Mimic.stub(Fountain.RuntimeDispatch, :for_agent, fn agent ->
              send(owner, :preflight_passed)

              receive do
                :ceiling_committed -> :ok
              after
                5_000 -> raise "ceiling barrier timed out"
              end

              Mimic.call_original(Fountain.RuntimeDispatch, :for_agent, [agent])
            end)

            params = %{"user_id" => user.id, "agent_id" => agent.id}

            params =
              case path do
                :attach -> Map.put(params, "sandbox_id", sandbox.id)
                :fresh -> Map.put(params, "sandbox_mode", "ephemeral")
              end

            Launch.start_conversation(params)
          end)

        try do
          assert_receive :preflight_passed, 5_000

          tightening =
            independent_writer(fn ->
              user
              |> Fountain.Accounts.User.execution_limits_changeset(%{max_model_turns: 2})
              |> Repo.update!()
            end)

          assert %Fountain.Accounts.User{} = Task.await(tightening)
          refute tightening.pid == admitting.pid
          send(admitting.pid, :ceiling_committed)

          assert {:error, {:execution_limits_unsupported, ["max_model_turns"]}} =
                   Task.await(admitting)

          # No conversation means no allowance: the row is keyed by it.
          assert Conversations.list_conversations(user.id) == []

          refute Repo.exists?(
                   from e in Fountain.Audit.Event,
                     where:
                       e.user_id == ^user.id and
                         e.action in [
                           "conversation.created",
                           "conversation.execution_allowance_created"
                         ]
                 )

          assert Repo.all(from s in Sandbox, where: s.user_id == ^user.id) == [sandbox]
          refute_received :unexpected_worker_started
        after
          Task.shutdown(admitting, :brutal_kill)
        end
      after
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        sandboxes = Repo.all(from s in Sandbox, where: s.user_id == ^user.id)
        Repo.delete!(user)
        for saved <- sandboxes, do: Repo.delete!(saved)
      end
    end)
  end

  for path <- [:fresh, :attach] do
    test "concurrent #{path} rotations retain only the winner after a PostgreSQL lock wait" do
      rotation_race(unquote(path))
    end
  end

  # The fresh rotation unbinds the old conversation inside
  # `with_sandbox_reservation/3`, which holds the global fleet advisory lock.
  # The row it needs is the one turn admission takes `FOR UPDATE`, so the wait
  # is bounded: a rotation that cannot have it is refused promptly rather than
  # holding every other tenant's provisioning behind it.
  test "a rotation that cannot take the old binding is refused, not left waiting" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user =
        Repo.insert!(%Fountain.Accounts.User{
          email: "rotation-busy-#{Ecto.UUID.generate()}@example.test",
          credit_balance_cents: 500,
          sandbox_limit_override: 20
        })

      Repo.insert!(%Fountain.Accounts.UserDataKey{
        user_id: user.id,
        wrapped_key: Fountain.Crypto.wrap_dek(Fountain.Crypto.generate_dek())
      })

      env = Fountain.Factory.insert_env(user_id: user.id)

      agent =
        Fountain.Factory.insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

      sandbox =
        Fountain.Factory.insert_sandbox(
          user_id: user.id,
          agent_id: agent.id,
          environment_id: env.id,
          status: "ready"
        )

      previous =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: sandbox,
          status: "idle",
          channel_id: "rotation"
        )

      owner = self()

      params = %{
        "user_id" => user.id,
        "agent_id" => agent.id,
        "channel_id" => "rotation",
        "fresh" => true,
        "sandbox_mode" => "ephemeral"
      }

      try do
        # Stands in for a turn being admitted on the conversation being rotated.
        holder =
          independent_writer(fn ->
            Repo.transaction(fn ->
              Repo.one(
                from c in Conversation, where: c.id == ^previous.id, lock: "FOR NO KEY UPDATE"
              )

              send(owner, :held)

              receive do
                :release -> :ok
              after
                15_000 -> raise "hold barrier timed out"
              end
            end)
          end)

        try do
          assert_receive :held, 5_000

          rotating =
            independent_writer(fn ->
              Fountain.ServerStart.stub_server_start(fn _, _ ->
                send(owner, :unexpected_worker_started)
                {:error, :fixture_rejection}
              end)

              started = System.monotonic_time(:millisecond)
              result = Launch.start_or_resume_conversation(params)
              {result, System.monotonic_time(:millisecond) - started}
            end)

          assert {{:error, changeset}, elapsed} = Task.await(rotating, 10_000)

          assert errors_on(changeset).channel_id == [
                   "the previous conversation is busy; retry the rotation"
                 ]

          # The point of the bound: it gave up while the holder was still
          # holding, rather than waiting the lock out under the fleet lock.
          assert elapsed < 5_000

          assert Repo.reload!(previous).channel_id == "rotation"
          assert Launch.channel_conversation(params).id == previous.id
          refute_received :unexpected_worker_started
        after
          # Let it commit and drop the row lock before cleanup runs: a
          # brutal_kill here leaves the backend holding `previous` long enough
          # for the cascading delete below to fail, and the fixtures leak.
          send(holder.pid, :release)
          Task.yield(holder, 5_000) || Task.shutdown(holder, :brutal_kill)
        end
      after
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        sandboxes = Repo.all(from s in Sandbox, where: s.user_id == ^user.id)
        Repo.delete!(user)
        for saved <- sandboxes, do: Repo.delete!(saved)
      end
    end)
  end

  defp rotation_race(path) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user =
        Repo.insert!(%Fountain.Accounts.User{
          email: "rotation-race-#{Ecto.UUID.generate()}@example.test",
          credit_balance_cents: 500,
          sandbox_limit_override: 20
        })

      Repo.insert!(%Fountain.Accounts.UserDataKey{
        user_id: user.id,
        wrapped_key: Fountain.Crypto.wrap_dek(Fountain.Crypto.generate_dek())
      })

      env = Fountain.Factory.insert_env(user_id: user.id)

      agent =
        Fountain.Factory.insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

      sandbox =
        Fountain.Factory.insert_sandbox(
          user_id: user.id,
          agent_id: agent.id,
          environment_id: env.id,
          status: "ready"
        )

      previous =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: sandbox,
          status: "idle",
          channel_id: "rotation"
        )

      owner = self()

      params = %{
        "user_id" => user.id,
        "agent_id" => agent.id,
        "channel_id" => "rotation",
        "fresh" => true
      }

      params =
        if path == :fresh,
          do: Map.put(params, "sandbox_mode", "ephemeral"),
          else: Map.put(params, "sandbox_id", sandbox.id)

      try do
        Repo.transaction(fn ->
          # An actual FK insert holds KEY SHARE on the old conversation.
          # Rotating its channel must coexist with references to that row.
          insert_allowance(previous.id)

          winner =
            independent_writer(fn ->
              Fountain.ServerStart.stub_server_start(fn _, _ -> {:ok, self()} end)

              # On an attach this runs in the machine's owner, which inserts
              # the conversation, so the barrier names the process it holds.
              Mimic.stub(Allowance, :new_changeset, fn id, limits ->
                send(owner, {:rotation_reserved, self()})

                receive do
                  :commit -> Mimic.call_original(Allowance, :new_changeset, [id, limits])
                after
                  5_000 -> raise "rotation barrier timed out"
                end
              end)

              Launch.start_or_resume_conversation(params)
            end)

          try do
            assert_receive {:rotation_reserved, reserving}, 5_000
            # Uncommitted unbinding is invisible: the existing conversation remains
            # the channel's binding while the winner waits to commit admission.
            assert Launch.channel_conversation(params).id == previous.id

            loser =
              independent_writer(fn ->
                Fountain.ServerStart.stub_server_start(fn _, _ ->
                  send(owner, :unexpected_worker_started)
                  {:error, :fixture_rejection}
                end)

                Launch.start_or_resume_conversation(params)
              end)

            try do
              assert_receive {:backend, winner_pid, winner_backend}, 5_000
              assert winner_pid == winner.pid
              assert_receive {:backend, loser_pid, loser_backend}, 5_000
              assert loser_pid == loser.pid
              refute winner_backend == loser_backend
              await_blocked(loser_backend, System.monotonic_time(:millisecond) + 5_000)
              send(reserving, :commit)
              assert {:ok, replacement, :created} = Task.await(winner)
              assert {:error, changeset} = Task.await(loser)
              assert errors_on(changeset).channel_id == ["binding changed; retry the rotation"]
              assert Launch.channel_conversation(params).id == replacement.id
              assert Repo.reload!(previous).channel_id == nil
              assert length(Conversations.list_conversations(user.id)) == 2
              expected_sandboxes = if path == :fresh, do: 2, else: 1

              assert Repo.aggregate(from(s in Sandbox, where: s.user_id == ^user.id), :count) ==
                       expected_sandboxes

              refute_received :unexpected_worker_started
            after
              Task.shutdown(loser, :brutal_kill)
            end
          after
            Task.shutdown(winner, :brutal_kill)
          end
        end)
      after
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        sandboxes = Repo.all(from s in Sandbox, where: s.user_id == ^user.id)
        Repo.delete!(user)
        for saved <- sandboxes, do: Repo.delete!(saved)
      end
    end)
  end

  defp race(mode) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      # These rows must be committed: sharing the test's sandbox connection would
      # serialize the queries in Elixir and never exercise PostgreSQL contention.
      {:ok, {user, allowance, sandbox_id}} =
        Repo.transaction(fn ->
          user =
            Repo.insert!(%Fountain.Accounts.User{
              email: "allowance-race-#{Ecto.UUID.generate()}@example.test"
            })

          conversation = insert_conversation(user_id: user.id)
          {user, insert_allowance(conversation.id), conversation.sandbox_id}
        end)

      owner = self()

      winner =
        independent_writer(fn ->
          Repo.transaction(fn ->
            updated =
              if mode == :stale do
                allowance |> Allowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update!()
              else
                {:ok, updated} =
                  Conversations.narrow_execution_allowance(allowance.conversation_id, user.id, %{
                    max_model_turns: 2
                  })

                updated
              end

            send(owner, :narrowed)

            receive do
              :commit -> updated
            after
              5_000 -> raise "commit barrier timed out"
            end
          end)
        end)

      try do
        assert_receive :narrowed, 5_000

        loser =
          independent_writer(fn ->
            if mode == :stale do
              allowance
              |> Allowance.narrow_changeset(%{max_model_turns: 5})
              |> Repo.update(stale_error_field: :revision)
            else
              request =
                if mode == :widen, do: %{max_model_turns: 5}, else: %{wall_time_seconds: 10}

              Conversations.narrow_execution_allowance(
                allowance.conversation_id,
                user.id,
                request
              )
            end
          end)

        try do
          assert_receive {:backend, winner_pid, winner_backend}, 5_000
          assert winner_pid == winner.pid
          assert_receive {:backend, loser_pid, loser_backend}, 5_000
          assert loser_pid == loser.pid
          refute winner_backend == loser_backend
          await_blocked(loser_backend, System.monotonic_time(:millisecond) + 5_000)
          send(winner.pid, :commit)
          assert {:ok, updated} = Task.await(winner)

          case {mode, Task.await(loser)} do
            {:stale, {:error, changeset}} ->
              assert errors_on(changeset).revision == ["is stale"]
              assert Repo.reload!(allowance) == updated

            {:widen, {:error, changeset}} ->
              assert errors_on(changeset).limits == ["execution_limits_widen: max_model_turns"]
              assert Repo.reload!(allowance) == updated

            {:disjoint, {:ok, final}} ->
              assert final.limits == %{"max_model_turns" => 2, "wall_time_seconds" => 10}
              assert Repo.reload!(allowance) == final
          end

          assert updated.limits["max_model_turns"] == 2
        after
          Task.shutdown(loser, :brutal_kill)
        end
      after
        Task.shutdown(winner, :brutal_kill)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        Repo.delete!(user)
        Repo.get!(Sandbox, sandbox_id) |> Repo.delete!()
        assert Repo.get(Allowance, allowance.conversation_id) == nil
        assert Repo.get(Sandbox, sandbox_id) == nil
      end
    end)
  end

  defp independent_writer(fun) do
    owner = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline, "no PostgreSQL lock wait observed"
      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end

  defp insert_allowance(conversation_id) do
    conversation_id
    |> Allowance.new_changeset(%{max_model_turns: 10, wall_time_seconds: 60})
    |> Repo.insert!()
  end
end
