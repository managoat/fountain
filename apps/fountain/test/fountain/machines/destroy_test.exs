defmodule Fountain.Machines.DestroyTest do
  @moduledoc """
  The one destroy protocol (ADR 0058 stage 5).

  What these pin is the *order* — fence, then intent, then the provider, then
  the finalize, then the trail — and what each step does when the one before
  it has already been done by somebody else. The three call sites that ask for
  this protocol keep their own suites (`lifecycle_fence_test.exs`,
  `termination_actor_fence_test.exs`, `termination_fallback_test.exs`); this
  file is the protocol on its own.

  `async: false`: the gate is application environment, and the gate-on cases
  run the protocol inside an owner process that needs the shared sandbox
  connection.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Audit
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp opts(ctx, extra \\ []) do
    Keyword.merge([actor: "system:conversation_server", reason: :terminated], extra)
    |> Keyword.put_new(:terminating_conversation_id, ctx.conv.id)
  end

  defp events(ctx, action), do: Audit.list_for_user(ctx.user.id, action_prefix: action)

  defp row(ctx), do: Repo.reload!(ctx.sandbox)

  # An owner outliving its test would hold a checked-in sandbox connection and
  # stay registered under an id the next test may reuse (as in `machine_test.exs`).
  defp stop_machine(sandbox_id) do
    case Machine.whereis(sandbox_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Horde.DynamicSupervisor.terminate_child(Fountain.MachineSupervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> Process.demonitor(ref, [:flush])
        end
    end
  end

  defp with_gate(value, fun) do
    previous = Application.fetch_env(:fountain, :machine_owner_enabled)
    Application.put_env(:fountain, :machine_owner_enabled, value)

    try do
      fun.()
    after
      case previous do
        {:ok, was} -> Application.put_env(:fountain, :machine_owner_enabled, was)
        :error -> Application.delete_env(:fountain, :machine_owner_enabled)
      end
    end
  end

  # A plain process standing in for a co-tenant's server: `whereis/1` only asks
  # the registry, and a cast is a message. Same shape as `lifecycle_actions_test.exs`.
  defp stand_in_server(conversation_id) do
    test = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conversation_id, nil)
           receive do: (msg -> send(test, {:cotenant, msg}))
         end},
        id: {:stand_in, conversation_id}
      )

    assert {:ok, ^pid} = ConversationServer.await_registered(conversation_id, 2_000)
    pid
  end

  describe "the happy path" do
    test "fences, stamps the intent, destroys, finalizes, audits, in that order", ctx do
      test = self()
      machine_name = ctx.sandbox.machine_name

      expect(Managoat.Sandbox, :destroy, fn %Handle{provider: :sprites, name: ^machine_name} ->
        # Everything before step 5, read from the row the way another node
        # would read it: no transaction, no lock, no struct we brought.
        refute Repo.in_transaction?()
        send(test, {:mid_destroy, Repo.reload!(ctx.sandbox)})
        :ok
      end)

      assert {:ok, :destroyed} = Destroy.run(ctx.sandbox.id, opts(ctx, reason: :idle))

      assert_received {:mid_destroy, mid}
      assert mid.teardown_requested_at, "the fence had not committed before the provider call"
      assert mid.reset_requested_at
      assert mid.transition == "destroying"
      assert mid.transition_reason == "idle"
      assert mid.status == "ready", "the row went terminal before the machine was gone"
      assert mid.lease_node == to_string(node())
      assert mid.lease_epoch == 1

      final = row(ctx)
      assert final.status == "terminated"
      assert final.terminated_at
      assert is_nil(final.transition)
      assert is_nil(final.transition_reason)
      # Released, and the epoch kept: epochs are monotonic and never reused.
      assert final.lease_epoch == 1
      assert is_nil(final.lease_node)
      assert is_nil(final.lease_until)

      assert [fence] = events(ctx, "sandbox.teardown_requested")
      assert fence.actor == "system:conversation_server"

      assert [destroyed] = events(ctx, "sandbox.destroyed")
      assert destroyed.actor == "system:conversation_server"
      assert destroyed.resource_type == "sandbox"
      assert destroyed.resource_id == ctx.sandbox.id

      assert destroyed.metadata == %{
               "reason" => "idle",
               "provider" => "sprites",
               "sprite_name" => machine_name
             }
    end

    test "the audit is written after the finalize commits, never before", ctx do
      # The rule ADR 0013 and the `Fountain.Audit` moduledoc both state: a
      # trail entry for work that has not committed is a lie the next reader
      # cannot detect. Observed from inside `Audit.record/1`.
      test = self()
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      stub(Audit, :record, fn attrs ->
        if attrs[:action] == "sandbox.destroyed" do
          refute Repo.in_transaction?()
          send(test, {:at_audit, Repo.reload!(ctx.sandbox)})
        end

        Mimic.call_original(Audit, :record, [attrs])
      end)

      assert {:ok, :destroyed} = Destroy.run(ctx.sandbox.id, opts(ctx))

      assert_received {:at_audit, at_audit}
      assert at_audit.status == "terminated"
      assert is_nil(at_audit.transition)
    end

    test "the request ip and a caller's own actor reach both events", ctx do
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      assert {:ok, :destroyed} =
               Destroy.run(
                 ctx.sandbox.id,
                 opts(ctx,
                   actor: "ui",
                   request_ip: "192.0.2.9",
                   fence_reason: "conversation_terminated"
                 )
               )

      assert [fence] = events(ctx, "sandbox.teardown_requested")
      assert fence.actor == "ui"
      assert fence.request_ip == "192.0.2.9"
      assert fence.metadata["reason"] == "conversation_terminated"

      assert [destroyed] = events(ctx, "sandbox.destroyed")
      assert destroyed.actor == "ui"
      assert destroyed.request_ip == "192.0.2.9"
      assert destroyed.metadata["reason"] == "terminated"
    end

    test "the co-tenants are told once, after the machine is gone", ctx do
      other =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "idle"
        )

      stand_in_server(other.id)
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      assert {:ok, :destroyed} =
               Destroy.run(
                 ctx.sandbox.id,
                 # No terminating conversation: with one, the fence would keep
                 # the machine *for* this co-tenant rather than destroy it.
                 actor: "system:conversation_server",
                 reason: :max_lifetime,
                 notify: {ctx.conv.id, "reclaimed", "max_lifetime", "the ceiling"}
               )

      sandbox_id = ctx.sandbox.id

      assert_receive {:cotenant,
                      {:"$gen_cast",
                       {:machine_gone, ^sandbox_id, "reclaimed", "max_lifetime", "the ceiling"}}},
                     2_000

      refute_receive {:cotenant, _}, 100
    end

    test "with no notice, nobody is told", ctx do
      other =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "idle"
        )

      stand_in_server(other.id)
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      assert {:ok, :destroyed} =
               Destroy.run(ctx.sandbox.id, actor: "self", reason: :reclaimed)

      refute_receive {:cotenant, _}, 200
    end
  end

  describe "the fence's answers" do
    test "a co-tenant holding the machine is kept, untouched and unrecorded", ctx do
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: ctx.sandbox,
        status: "idle"
      )

      reject(Managoat.Sandbox, :destroy, 1)

      assert {:ok, :kept} = Destroy.run(ctx.sandbox.id, opts(ctx))

      kept = row(ctx)
      assert kept.status == "ready"
      refute kept.reset_requested_at
      refute kept.teardown_requested_at
      assert is_nil(kept.transition)
      # The lease was taken to make the decision and given back; the epoch it
      # spent is not reused.
      assert kept.lease_epoch == 1
      assert is_nil(kept.lease_node)

      assert events(ctx, "sandbox.teardown_requested") == []
      assert events(ctx, "sandbox.destroyed") == []
    end

    test "a persistent home is kept", ctx do
      ctx.sandbox |> Ecto.Changeset.change(mode: "persistent") |> Repo.update!()
      reject(Managoat.Sandbox, :destroy, 1)

      assert {:ok, :kept} = Destroy.run(ctx.sandbox.id, opts(ctx))
      assert row(ctx).status == "ready"
      assert events(ctx, "sandbox.destroyed") == []
    end

    for terminal <- ["terminated", "failed"] do
      test "a row already #{terminal} writes nothing and calls nothing", ctx do
        stamped = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600)

        ctx.sandbox
        |> Ecto.Changeset.change(status: unquote(terminal), terminated_at: stamped)
        |> Repo.update!()

        reject(Managoat.Sandbox, :destroy, 1)

        assert {:ok, :already_terminal} = Destroy.run(ctx.sandbox.id, opts(ctx))

        done = row(ctx)
        assert done.status == unquote(terminal)
        assert DateTime.compare(done.terminated_at, stamped) == :eq
        assert is_nil(done.transition)
        assert events(ctx, "sandbox.destroyed") == []
      end
    end

    test "a refusal is returned as it came, with nothing destroyed", ctx do
      expect(Fountain.Conversations.Lifecycle, :fence_sandbox_for_teardown, fn _, _ ->
        {:error, :sandbox_unavailable}
      end)

      reject(Managoat.Sandbox, :destroy, 1)

      assert {:error, :sandbox_unavailable} = Destroy.run(ctx.sandbox.id, opts(ctx))
      assert row(ctx).status == "ready"
      assert is_nil(row(ctx).transition)
    end

    test "a machine with no row at all is :not_found", ctx do
      id = Ecto.UUID.generate()
      reject(Managoat.Sandbox, :destroy, 1)
      assert {:error, :not_found} = Destroy.run(id, opts(ctx))
    end
  end

  describe "the provider" do
    test "an error is logged and the fenced row is still retired", ctx do
      expect(Managoat.Sandbox, :destroy, fn _ -> {:error, {:unavailable, :timeout}} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :destroyed} = Destroy.run(ctx.sandbox.id, opts(ctx))
        end)

      assert log =~ "provider destroy failed for #{ctx.sandbox.machine_name}"
      assert row(ctx).status == "terminated"
      assert is_nil(row(ctx).transition)
      assert [_] = events(ctx, "sandbox.destroyed")
    end

    test "a machine that is already gone is success, not an error", ctx do
      expect(Managoat.Sandbox, :destroy, fn _ -> {:error, :not_found} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :destroyed} = Destroy.run(ctx.sandbox.id, opts(ctx))
        end)

      refute log =~ "provider destroy failed"
      assert row(ctx).status == "terminated"
    end

    test "the machine destroyed is the one the row names, not a caller's handle", ctx do
      # The protocol takes no handle: the owner reads the machine it owns. This
      # is what lets a caller that has already dropped its adapter — a reclaim,
      # a dead-server terminate — still reach the machine.
      renamed = "test-sprite-renamed-#{System.unique_integer([:positive])}"

      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [machine_name: renamed, provider: "daytona"]
      )

      expect(Managoat.Sandbox, :destroy, fn %Handle{provider: :daytona, name: ^renamed} -> :ok end)

      assert {:ok, :destroyed} = Destroy.run(ctx.sandbox.id, opts(ctx))
      assert row(ctx).status == "terminated"
      assert [destroyed] = events(ctx, "sandbox.destroyed")
      assert destroyed.metadata["provider"] == "daytona"
      assert destroyed.metadata["sprite_name"] == renamed
    end
  end

  describe "the lease" do
    test "a takeover between the intent and the finalize supersedes this destroy", ctx do
      # The ADR's central claim, reproduced: a node whose lease has been taken
      # over can still complete the provider call it started, and the
      # compare-and-set is what makes its write invisible.
      expect(Managoat.Sandbox, :destroy, fn _ ->
        assert {1, _} =
                 Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
                   set: [
                     lease_epoch: 99,
                     lease_node: "successor@node",
                     lease_until: DateTime.add(DateTime.utc_now(), 60, :second)
                   ]
                 )

        :ok
      end)

      assert {:error, :superseded} = Destroy.run(ctx.sandbox.id, opts(ctx))

      superseded = row(ctx)
      assert superseded.status == "ready", "a superseded owner wrote the row terminal"
      assert superseded.transition == "destroying"
      assert superseded.lease_epoch == 99
      # The fence is committed — the machine is closed to admission, which is
      # what the successor needs — but the destroy is not claimed as done.
      assert superseded.teardown_requested_at
      assert events(ctx, "sandbox.destroyed") == []
    end

    test "an interrupted destroy is continued from the provider call", ctx do
      # The forged row a crashed owner leaves: the fence is committed, the
      # intent is stamped, the lease has run out, and nothing finalized.
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [
          lease_epoch: 7,
          lease_node: "dead@node",
          lease_until: past,
          transition: "destroying",
          transition_reason: "terminated",
          reset_requested_at: past,
          teardown_requested_at: past
        ]
      )

      expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)
      # Continued, not restarted: the fence is not asked a second time, so no
      # second intent event is recorded for a teardown already requested.
      reject(Fountain.Conversations.Lifecycle, :fence_sandbox_for_teardown, 2)

      assert {:ok, :destroyed} = Destroy.run(ctx.sandbox.id, opts(ctx))

      finished = row(ctx)
      assert finished.status == "terminated"
      assert finished.terminated_at
      assert is_nil(finished.transition)
      assert finished.lease_epoch == 8, "the continuation ran under a new epoch"
      assert is_nil(finished.lease_node)

      assert events(ctx, "sandbox.teardown_requested") == []
      assert [_] = events(ctx, "sandbox.destroyed")
    end

    test "a live lease held elsewhere is waited out, then refused", ctx do
      {:ok, 1} = Lease.claim(ctx.sandbox.id, "other@node", 30_000)
      reject(Managoat.Sandbox, :destroy, 1)

      started = System.monotonic_time(:millisecond)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :machine_busy} =
                   Destroy.run(ctx.sandbox.id, opts(ctx, lease_ttl_ms: 400))
        end)

      waited = System.monotonic_time(:millisecond) - started

      assert waited >= 200, "gave up without waiting (#{waited}ms)"
      assert waited < 4_000, "waited past its own bound (#{waited}ms)"
      assert log =~ "lease held by other@node"

      busy = row(ctx)
      assert busy.status == "ready"
      assert busy.lease_epoch == 1
      assert is_nil(busy.transition)
      assert events(ctx, "sandbox.destroyed") == []
    end

    test "a lease released while the wait runs is claimed rather than refused", ctx do
      {:ok, 1} = Lease.claim(ctx.sandbox.id, "other@node", 30_000)
      expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      test = self()

      releaser =
        spawn(fn ->
          receive do: (:go -> :ok)
          Process.sleep(100)
          send(test, {:released, Lease.release(ctx.sandbox.id, 1)})
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), releaser)
      send(releaser, :go)

      assert {:ok, :destroyed} = Destroy.run(ctx.sandbox.id, opts(ctx, lease_ttl_ms: 5_000))
      assert_received {:released, :ok}
      assert row(ctx).status == "terminated"
      assert row(ctx).lease_epoch == 2
    end
  end

  describe "refusals before anything happens" do
    test "an enclosing transaction is refused before the row is read", ctx do
      reject(Managoat.Sandbox, :destroy, 1)

      assert {:ok, {:error, :transaction_open}} =
               Repo.transaction(fn -> Destroy.run(ctx.sandbox.id, opts(ctx)) end)

      assert row(ctx).status == "ready"
      assert row(ctx).lease_epoch == 0
      refute row(ctx).teardown_requested_at
    end

    test "a missing actor or reason is a caller bug, not an answer", ctx do
      assert_raise KeyError, fn -> Destroy.run(ctx.sandbox.id, reason: :terminated) end
      assert_raise KeyError, fn -> Destroy.run(ctx.sandbox.id, actor: "self") end

      assert_raise ArgumentError, ~r/:reason must be an atom/, fn ->
        Destroy.run(ctx.sandbox.id, actor: "self", reason: "terminated")
      end

      assert row(ctx).lease_epoch == 0
    end
  end

  describe "the gate chooses where, not what" do
    test "inline and in-process leave the same row and the same trail", ctx do
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      other_sandbox =
        insert_sandbox(user_id: other_user.id, agent_id: other_agent.id, status: "ready")

      other_conv =
        insert_conversation(
          user_id: other_user.id,
          agent: other_agent,
          sandbox: other_sandbox,
          status: "idle"
        )

      on_exit(fn -> stop_machine(other_sandbox.id) end)

      with_gate(false, fn ->
        assert {:ok, :destroyed} =
                 Machine.destroy(ctx.sandbox.id,
                   actor: "api",
                   reason: :terminated,
                   terminating_conversation_id: ctx.conv.id
                 )

        assert Machine.whereis(ctx.sandbox.id) == nil, "the gate was off and an owner started"
      end)

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(other_sandbox.id)
        Mimic.allow(Managoat.Sandbox, self(), owner)

        assert {:ok, :destroyed} =
                 Machine.destroy(other_sandbox.id,
                   actor: "api",
                   reason: :terminated,
                   terminating_conversation_id: other_conv.id
                 )
      end)

      inline = Repo.reload!(ctx.sandbox)
      in_process = Repo.reload!(other_sandbox)

      assert inline.status == in_process.status
      assert inline.transition == in_process.transition
      assert inline.lease_epoch == in_process.lease_epoch
      assert inline.lease_node == in_process.lease_node
      assert inline.teardown_requested_at && in_process.teardown_requested_at

      assert actions(ctx.user.id) == actions(other_user.id)

      assert [%{actor: "api", metadata: %{"reason" => "terminated"}}] =
               events(ctx, "sandbox.destroyed")

      assert [%{actor: "api", metadata: %{"reason" => "terminated"}}] =
               Audit.list_for_user(other_user.id, action_prefix: "sandbox.destroyed")
    end

    test "with the gate on, two destroys of one machine produce one of each", ctx do
      calls = :counters.new(1, [])
      test = self()

      stub(Managoat.Sandbox, :destroy, fn _ ->
        :counters.add(calls, 1, 1)
        # Wide enough that the second caller is certainly queued behind this
        # one rather than arriving after it finished.
        Process.sleep(150)
        :ok
      end)

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Managoat.Sandbox, self(), owner)

        racers =
          for _ <- 1..2 do
            pid =
              spawn(fn ->
                send(
                  test,
                  {:result,
                   Machine.destroy(ctx.sandbox.id,
                     actor: "system:conversation_server",
                     reason: :terminated,
                     terminating_conversation_id: ctx.conv.id
                   )}
                )
              end)

            Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
            pid
          end

        assert length(racers) == 2

        results =
          for _ <- 1..2 do
            assert_receive {:result, result}, 10_000
            result
          end

        assert Enum.sort(results) == [{:ok, :already_terminal}, {:ok, :destroyed}]
      end)

      assert :counters.get(calls, 1) == 1, "the machine was destroyed twice"
      assert [_] = events(ctx, "sandbox.destroyed")
      assert [_] = events(ctx, "sandbox.teardown_requested")
      assert row(ctx).status == "terminated"
    end
  end

  defp actions(user_id) do
    user_id
    |> Audit.list_recent_for_user(200)
    |> Enum.map(& &1.action)
    |> Enum.sort()
  end
end
