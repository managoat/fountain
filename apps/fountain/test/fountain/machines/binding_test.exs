defmodule Fountain.Machines.BindingTest do
  @moduledoc """
  The binding protocol (ADR 0058 stage 8b): attach, detach, retarget, the
  turns the owner ends, the owner-only `machine_gone`, the early takeover of a
  lease whose node is gone, and the deadline a late resume now carries.

  `async: false`: the gate is application environment, the gate-on cases run
  the protocol inside an owner process that needs the shared sandbox
  connection, and the race cases use `unboxed_run`.

  **What `reject(&Managoat.Sandbox.destroy/1)` is worth here, and what it is
  not** (round 1). `Destroy.destroy_at_provider/2` rescues a raising adapter
  and finalizes the row, and Mimic's `UnexpectedCallError` is a raise — so a
  provider call this file rejects is swallowed into a logged failure rather
  than failing the test. Every `reject` below is therefore belt to an
  assertion's braces: the outcome (`{:ok, :kept}`) or the row (`status ==
  "ready"`) is what actually catches a provider call that should not have
  happened. Where "no round trip" is the whole claim, the pin is a stub that
  reports and a `refute_received`, not a `reject`. Same shape inside a `stub`:
  an assertion that fails there surfaces as the protocol's own error tuple, so
  the outer assertion is the one doing the work.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Binding
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Park
  alias Fountain.Machines.Renewal

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: env.id,
        mode: "ephemeral",
        status: "ready"
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, env: env, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp attach_attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        sandbox_id: ctx.sandbox.id,
        agent_id: ctx.agent.id,
        vault_id: nil,
        environment_id: ctx.env.id,
        user_id: ctx.user.id,
        runtime: ctx.agent.runtime,
        status: "idle",
        source: "api",
        labels: %{}
      },
      overrides
    )
  end

  defp detach_opts(ctx, overrides \\ []) do
    Keyword.merge([conversation_id: ctx.conv.id, actor: "self", destroy: true], overrides)
  end

  defp conversations(ctx) do
    Repo.all(
      from c in Conversation, where: c.sandbox_id == ^ctx.sandbox.id, order_by: c.inserted_at
    )
  end

  defp stamp(ctx, sets) do
    Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id), set: sets)
  end

  defp quietly(fun), do: capture_log(fun)

  defp stage_reasons(stage, state, reason) do
    Repo.all(from e in LogEvent, where: e.stage == ^stage and e.state == ^state)
    |> Enum.filter(fn e -> Jason.decode!(e.data)["reason"] == reason end)
  end

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

  # A plain process standing in for a conversation's server: `whereis/1` only
  # asks the registry, and the cast the owner sends lands in this mailbox.
  defp stand_in_server(conversation_id) do
    test = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conversation_id, nil)
           forward_forever(test, conversation_id)
         end},
        id: {:stand_in, conversation_id}
      )

    wait_until(fn ->
      Fountain.Conversations.ConversationServer.whereis(conversation_id) == pid
    end)

    pid
  end

  # Forwards **every** message, not the first. A stand-in that takes one and
  # exits cannot see a second notice, and round 1 found one: a persistent
  # home's replacement told each co-tenant twice and both pins were blind to
  # it. A real `ConversationServer` stops on the first cast, so the count is
  # only ever visible from here.
  defp forward_forever(test, conversation_id) do
    receive do
      msg ->
        send(test, {:cotenant, conversation_id, msg})
        forward_forever(test, conversation_id)
    end
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    unless fun.() do
      assert System.monotonic_time(:millisecond) < deadline, "condition never held"
      Process.sleep(10)
      wait_until(fun, deadline)
    end
  end

  # ── attach ────────────────────────────────────────────────────────────────

  describe "attach" do
    for gate <- [false, true] do
      test "binds a conversation to the machine, with its allowance (gate #{gate})", ctx do
        with_gate(unquote(gate), fn ->
          assert {:ok, %Conversation{} = attached, allowance} =
                   Machine.attach(ctx.sandbox.id, attach_attrs(ctx), actor: "api")

          assert attached.sandbox_id == ctx.sandbox.id
          assert allowance.conversation_id == attached.id
          assert Machine.whereis(ctx.sandbox.id) != nil == unquote(gate)
        end)

        assert length(conversations(ctx)) == 2
      end
    end

    test "the machine's rule is decided under the lock: fence, status, identity, runtime, lease",
         ctx do
      other_agent = insert_agent(user_id: ctx.user.id, runtime: "claude")

      assert {:error, :sandbox_identity_mismatch} =
               Machine.attach(ctx.sandbox.id, attach_attrs(ctx, %{agent_id: other_agent.id}))

      other_env = insert_env(user_id: ctx.user.id)

      assert {:error, :sandbox_identity_mismatch} =
               Machine.attach(ctx.sandbox.id, attach_attrs(ctx, %{environment_id: other_env.id}))

      ctx.agent |> Ecto.Changeset.change(runtime: "opencode") |> Repo.update!()

      assert {:error, :sandbox_runtime_mismatch} =
               Machine.attach(ctx.sandbox.id, attach_attrs(ctx, %{runtime: "opencode"}))

      ctx.agent |> Repo.reload!() |> Ecto.Changeset.change(runtime: "claude") |> Repo.update!()

      stamp(ctx, status: "pending")
      assert {:error, {:sandbox_not_attachable, "pending"}} = attach(ctx)
      stamp(ctx, status: "ready")

      stamp(ctx, reset_requested_at: DateTime.utc_now())
      assert {:error, :sandbox_reset_pending} = attach(ctx)
      stamp(ctx, reset_requested_at: nil)

      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, "other@node", 60_000)
      started = System.monotonic_time(:millisecond)
      assert {:error, :sandbox_unavailable} = attach(ctx)

      assert System.monotonic_time(:millisecond) - started < 1_000,
             "an attach waited on a live lease; stage 6a made the door refuse at once"

      assert length(conversations(ctx)) == 1
    end

    test "a permanent refusal outranks a live lease", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, "other@node", 60_000)
      other_agent = insert_agent(user_id: ctx.user.id, runtime: "claude")

      assert {:error, :sandbox_identity_mismatch} =
               Machine.attach(ctx.sandbox.id, attach_attrs(ctx, %{agent_id: other_agent.id}))
    end

    test "refuses an enclosing transaction at the door and in the protocol", ctx do
      Repo.transaction(fn ->
        assert {:error, :provider_transaction_open} = attach(ctx)
        assert {:error, :transaction_open} = Binding.attach(ctx.sandbox.id, attach_attrs(ctx))
      end)

      assert length(conversations(ctx)) == 1
    end

    test "an attach whose caller has given up is refused, not run late (gate on)", ctx do
      # Rule 17, the shape 8a's reviewers found: a park holding the owner past
      # the caller's timeout. The caller is answered 503; the queued attach
      # then reaches the front of the mailbox and, reading its deadline,
      # writes nothing.
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(700)
        :ok
      end)

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Managoat.Sandbox, self(), owner)
        sandbox_id = ctx.sandbox.id

        park =
          Task.async(fn ->
            capture_log(fn ->
              send(
                test,
                {:park, Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)}
              )
            end)
          end)

        assert_receive :suspending, 2_000

        quietly(fn ->
          assert {:error, :sandbox_unavailable} =
                   Machine.attach(ctx.sandbox.id, attach_attrs(ctx), attach_timeout_ms: 200)
        end)

        assert_receive {:park, {:ok, :parked}}, 5_000
        Task.await(park)
        assert %Fountain.Machines.Occupancy{} = Machine.who_is_here(ctx.sandbox.id)
      end)

      assert length(conversations(ctx)) == 1, "the owner attached a conversation nobody asked for"
      assert Repo.reload!(ctx.sandbox).status == "suspended"
    end

    test "the write-side deadline refuses on its own, against the clock the row was read with",
         ctx do
      # The inner half of rule 17, reached without the owner's pre-check —
      # `Binding.attach/3` is the protocol, `Machine.attach/3` is the door that
      # checks first. Round 1 found this half with zero coverage: planting
      # `expired?/2` to answer false left 2158 tests green, while the two
      # "whose caller has given up" tests above exercise only the owner's
      # check. 8a's `:admission_expired` has had its own case since it was
      # written; this is the pair.
      past = DateTime.add(DateTime.utc_now(), -5, :second)

      assert {:error, :attach_expired} =
               Binding.attach(ctx.sandbox.id, attach_attrs(ctx), deadline: past)

      assert length(conversations(ctx)) == 1, "an expired attach wrote a conversation row"

      # The positive control, and the reason the check is inside the
      # transaction: the same call with a deadline it is inside lands.
      future = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, %Conversation{}, _allowance} =
               Binding.attach(ctx.sandbox.id, attach_attrs(ctx), deadline: future)

      assert length(conversations(ctx)) == 2
    end

    test "and a caller still waiting when the park finishes is attached (the positive control)",
         ctx do
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(300)
        :ok
      end)

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Managoat.Sandbox, self(), owner)
        sandbox_id = ctx.sandbox.id

        park =
          Task.async(fn ->
            capture_log(fn ->
              send(
                test,
                {:park, Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)}
              )
            end)
          end)

        assert_receive :suspending, 2_000

        # Onto the parked machine: `suspended` is attachable, as it always was.
        assert {:ok, %Conversation{}, _allowance} =
                 Machine.attach(ctx.sandbox.id, attach_attrs(ctx), attach_timeout_ms: 5_000)

        assert_receive {:park, {:ok, :parked}}, 5_000
        Task.await(park)
      end)

      assert length(conversations(ctx)) == 2
    end

    test "an owner that cannot run the attach refuses rather than attaching inline", ctx do
      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Binding, self(), owner)
        stub(Binding, :attach, fn _id, _attrs, _opts -> raise "no clause for {:attach, ..}" end)

        quietly(fn ->
          assert {:error, :sandbox_unavailable} = attach(ctx)
        end)
      end)

      assert length(conversations(ctx)) == 1
    end

    test "the refcount is the rows: a conversation that ended without a detach stops counting",
         ctx do
      # The second door (rule 16): nothing decremented, because nothing was
      # ever incremented. A cotenant written `failed` by its provision, or
      # terminal by a sweep, is not held by anyone.
      cotenant = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)
      assert Binding.held_by_other?(ctx.sandbox.id, ctx.conv.id)

      cotenant |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
      refute Binding.held_by_other?(ctx.sandbox.id, ctx.conv.id)

      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      quietly(fn ->
        assert {:ok, :destroyed} = Machine.detach(ctx.sandbox.id, detach_opts(ctx))
      end)

      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end
  end

  defp attach(ctx), do: Machine.attach(ctx.sandbox.id, attach_attrs(ctx))

  # ── detach ────────────────────────────────────────────────────────────────

  describe "detach" do
    test "the last detach on an ephemeral machine destroys it", ctx do
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      quietly(fn ->
        assert {:ok, :destroyed} = Machine.detach(ctx.sandbox.id, detach_opts(ctx))
      end)

      assert Repo.reload!(ctx.sandbox).status == "terminated"
      assert [_] = Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.destroyed")
    end

    test "a co-tenant keeps the machine, and so does the mode", ctx do
      reject(&Managoat.Sandbox.destroy/1)
      insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)

      assert {:ok, :kept} = Machine.detach(ctx.sandbox.id, detach_opts(ctx))
      refute Repo.reload!(ctx.sandbox).reset_requested_at

      stamp(ctx, mode: "persistent")

      Repo.delete_all(
        from c in Conversation, where: c.sandbox_id == ^ctx.sandbox.id and c.id != ^ctx.conv.id
      )

      assert {:ok, :kept} = Machine.detach(ctx.sandbox.id, detach_opts(ctx))
      assert Repo.reload!(ctx.sandbox).status == "ready"
    end

    test "without destroy: true the fence commits and the machine is the caller's to finish",
         ctx do
      reject(&Managoat.Sandbox.destroy/1)

      assert {:ok, :detached} = Machine.detach(ctx.sandbox.id, detach_opts(ctx, destroy: false))

      assert Repo.reload!(ctx.sandbox).reset_requested_at
      assert Repo.reload!(ctx.sandbox).teardown_requested_at
      assert Repo.reload!(ctx.sandbox).status == "ready"
      # The door is closed: the fence refuses a new attach in the same breath.
      assert {:error, :sandbox_reset_pending} = attach(ctx)
    end

    test "refuses a live lease after waiting, and writes no fence", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, "other@node", 60_000)
      started = System.monotonic_time(:millisecond)

      quietly(fn ->
        assert {:error, :sandbox_unavailable} =
                 Machine.detach(ctx.sandbox.id, detach_opts(ctx, busy_wait_ms: 600))
      end)

      waited = System.monotonic_time(:millisecond) - started
      assert waited >= 250, "the wait gave up without waiting at all"
      assert waited < 5_000
      refute Repo.reload!(ctx.sandbox).reset_requested_at
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "the fence's own deadline refuses on its own, and writes no fence", ctx do
      # The detach's half of the pair above, reached through the protocol so
      # the owner's pre-check is not in the way. `refuse_busy_or_expired/2`
      # reads one clock after the locked row and rolls the fence back.
      past = DateTime.add(DateTime.utc_now(), -5, :second)

      assert {:error, :detach_expired} =
               Binding.detach(ctx.sandbox.id, conversation_id: ctx.conv.id, deadline: past)

      fenced = Repo.reload!(ctx.sandbox)
      refute fenced.teardown_requested_at, "an expired detach fenced the machine"
      refute fenced.reset_requested_at
      assert fenced.status == "ready"

      # The positive control: the same detach inside its deadline decides.
      future = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, :detached} =
               Binding.detach(ctx.sandbox.id, conversation_id: ctx.conv.id, deadline: future)

      assert Repo.reload!(ctx.sandbox).teardown_requested_at
    end

    test "a detach whose caller has given up is refused, not run late (gate on)", ctx do
      # A fence written for a caller told 503 would close the machine to
      # admission with this server still serving on it.
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(700)
        :ok
      end)

      reject(&Managoat.Sandbox.destroy/1)

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Managoat.Sandbox, self(), owner)
        sandbox_id = ctx.sandbox.id

        park =
          Task.async(fn ->
            capture_log(fn ->
              send(
                test,
                {:park, Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)}
              )
            end)
          end)

        assert_receive :suspending, 2_000

        quietly(fn ->
          assert {:error, :sandbox_unavailable} =
                   Machine.detach(ctx.sandbox.id, detach_opts(ctx, detach_timeout_ms: 200))
        end)

        assert_receive {:park, {:ok, :parked}}, 5_000
        Task.await(park)
        assert %Fountain.Machines.Occupancy{} = Machine.who_is_here(ctx.sandbox.id)
      end)

      refute Repo.reload!(ctx.sandbox).reset_requested_at, "the owner fenced a machine for nobody"
      assert Repo.reload!(ctx.sandbox).status == "suspended"
    end

    test "a release keeps the machine and runs inline whichever way the gate is set", ctx do
      reject(&Managoat.Sandbox.destroy/1)

      with_gate(true, fn ->
        assert {:ok, :released} =
                 Machine.detach(ctx.sandbox.id, conversation_id: ctx.conv.id, policy: :keep)

        assert Machine.whereis(ctx.sandbox.id) == nil, "a release started an owner"
      end)

      assert Repo.reload!(ctx.conv).status == "terminated"
      assert Repo.reload!(ctx.sandbox).status == "ready"
      refute Repo.reload!(ctx.sandbox).reset_requested_at
    end

    test "a release refuses a running turn only when a server is driving it", ctx do
      insert_turn(ctx.conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})

      assert {:error, :busy} =
               Machine.detach(ctx.sandbox.id,
                 conversation_id: ctx.conv.id,
                 policy: :keep,
                 actor_alive?: true
               )

      assert {:ok, :released} =
               Machine.detach(ctx.sandbox.id,
                 conversation_id: ctx.conv.id,
                 policy: :keep,
                 actor_alive?: false
               )
    end

    test "detach and park, in both orders", ctx do
      # Park first: the park holds the lease at the provider, the detach
      # waits it out and is refused, nothing is fenced.
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(700)
        :ok
      end)

      sandbox_id = ctx.sandbox.id

      park =
        Task.async(fn ->
          capture_log(fn ->
            Park.run(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)
          end)
        end)

      assert_receive :suspending, 2_000

      quietly(fn ->
        assert {:error, :sandbox_unavailable} =
                 Machine.detach(ctx.sandbox.id, detach_opts(ctx, busy_wait_ms: 300))
      end)

      Task.await(park)
      refute Repo.reload!(ctx.sandbox).reset_requested_at
      assert Repo.reload!(ctx.sandbox).status == "suspended"

      # Detach first: the machine is gone, and the park that follows finds it.
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      quietly(fn ->
        assert {:ok, :destroyed} = Machine.detach(ctx.sandbox.id, detach_opts(ctx))
      end)

      quietly(fn ->
        assert {:ok, :already_terminal} =
                 Park.run(ctx.sandbox.id, actor: "system:sandbox_reaper", reason: :idle)
      end)
    end
  end

  # ── attach and detach on real connections (the lock) ──────────────────────

  describe "an attach and a last detach of one machine, on real connections" do
    # The attach holds 4316 for its transaction; the detach's fence takes the
    # same lock. Whichever arrives second waits on PostgreSQL and then reads
    # what the first committed: an attach that landed makes the detach `:kept`;
    # a fence that landed makes the attach `:sandbox_reset_pending`.
    test "attach first: the detach waits on the lock, then keeps the machine it finds shared",
         _ctx do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {user, env, agent, sandbox, conv} = fixture()
        owner = self()
        handler = {__MODULE__, make_ref()}

        :telemetry.attach(
          handler,
          [:fountain, :repo, :query],
          &__MODULE__.pause_after_lock/4,
          owner
        )

        attach =
          independent(fn ->
            Process.put(:pause_binding_test, true)
            Binding.attach(sandbox.id, fixture_attrs(user, env, agent, sandbox))
          end)

        try do
          assert_receive :locked, 5_000

          detach =
            independent(fn ->
              reject(&Managoat.Sandbox.destroy/1)

              capture_log(fn ->
                send(
                  owner,
                  {:detach,
                   Binding.detach(sandbox.id,
                     conversation_id: conv.id,
                     actor: "self",
                     destroy: true
                   )}
                )
              end)
            end)

          try do
            detach_pid = detach.pid
            assert_receive {:backend, ^detach_pid, detach_backend}, 5_000
            await_blocked(detach_backend, System.monotonic_time(:millisecond) + 5_000)
            assert Task.yield(detach, 0) == nil

            send(attach.pid, :commit)
            assert {:ok, %Conversation{}, _} = Task.await(attach)

            assert_receive {:detach, {:ok, :kept}}, 5_000
            Task.await(detach)
            assert Repo.reload!(sandbox).status == "ready"
            refute Repo.reload!(sandbox).reset_requested_at
          after
            Task.shutdown(detach, :brutal_kill)
          end
        after
          Task.shutdown(attach, :brutal_kill)
          :telemetry.detach(handler)
          discard(user, [sandbox])
        end
      end)
    end

    test "detach first: the attach waits on the lock, then reads the fence", _ctx do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {user, env, agent, sandbox, conv} = fixture()
        owner = self()
        handler = {__MODULE__, make_ref()}

        :telemetry.attach(
          handler,
          [:fountain, :repo, :query],
          &__MODULE__.pause_after_lock/4,
          owner
        )

        detach =
          independent(fn ->
            Process.put(:pause_binding_test, true)
            stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

            capture_log(fn ->
              Binding.detach(sandbox.id, conversation_id: conv.id, actor: "self", destroy: true)
            end)
          end)

        try do
          assert_receive :locked, 5_000

          attach =
            independent(fn ->
              send(
                owner,
                {:attach, Binding.attach(sandbox.id, fixture_attrs(user, env, agent, sandbox))}
              )
            end)

          try do
            attach_pid = attach.pid
            assert_receive {:backend, ^attach_pid, attach_backend}, 5_000
            await_blocked(attach_backend, System.monotonic_time(:millisecond) + 5_000)
            assert Task.yield(attach, 0) == nil

            send(detach.pid, :commit)
            Task.await(detach)

            # The attach read the row after the fence committed. By the time it
            # got the lock the destroy may have finished too, in which case the
            # status clause answers; either way no row was inserted.
            assert_receive {:attach, {:error, reason}}, 5_000
            assert reason in [:sandbox_reset_pending, {:sandbox_not_attachable, "terminated"}]
            Task.await(attach)

            assert Repo.aggregate(from(c in Conversation, where: c.user_id == ^user.id), :count) ==
                     1
          after
            Task.shutdown(attach, :brutal_kill)
          end
        after
          Task.shutdown(detach, :brutal_kill)
          :telemetry.detach(handler)
          discard(user, [sandbox])
        end
      end)
    end

    test "two attaches both land, serialized on the lock", _ctx do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {user, env, agent, sandbox, _conv} = fixture()

        try do
          tasks =
            for _ <- 1..2 do
              independent(fn ->
                Binding.attach(sandbox.id, fixture_attrs(user, env, agent, sandbox))
              end)
            end

          for task <- tasks do
            assert {:ok, %Conversation{}, _} = Task.await(task, 5_000)
          end

          assert Repo.aggregate(
                   from(c in Conversation, where: c.sandbox_id == ^sandbox.id),
                   :count
                 ) == 3
        after
          discard(user, [sandbox])
        end
      end)
    end
  end

  # The turn's status as the `parking` stamp's own statement completes — read
  # on the same connection, right behind it.
  def report_stamp(_event, _measurements, %{query: query, params: params}, {test, turn_id}) do
    if String.contains?(query, "UPDATE \"sandboxes\"") and "parking" in params do
      send(test, {:stamped, Repo.get!(Turn, turn_id).status})
    end
  end

  # Pauses the paused process right after it takes the machine's advisory
  # lock, so the other side can be shown waiting on it.
  def pause_after_lock(_event, _measurements, %{query: query}, owner) do
    # The machine's lock and not the tenant's source lock, which the attach
    # takes first and which is also an advisory lock.
    if Process.get(:pause_binding_test, false) and
         String.contains?(query, "pg_advisory_xact_lock($1, $2)") do
      Process.delete(:pause_binding_test)
      send(owner, :locked)

      receive do
        :commit -> :ok
      after
        10_000 -> :ok
      end
    end
  end

  defp fixture do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: env.id,
        mode: "ephemeral",
        status: "ready"
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {user, env, agent, sandbox, conv}
  end

  defp fixture_attrs(user, env, agent, sandbox) do
    %{
      sandbox_id: sandbox.id,
      agent_id: agent.id,
      vault_id: nil,
      environment_id: env.id,
      user_id: user.id,
      runtime: agent.runtime,
      status: "idle",
      source: "api",
      labels: %{}
    }
  end

  defp independent(fun) do
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
      assert System.monotonic_time(:millisecond) < deadline,
             "no PostgreSQL advisory-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end

  # `unboxed_run` commits, so the rows a race case makes are removed by hand.
  defp discard(user, sandboxes) do
    Repo.delete_all(from e in Audit.Event, where: e.user_id == ^user.id)
    Repo.delete_all(from e in Fountain.Billing.UsageEvent, where: e.user_id == ^user.id)
    Repo.delete_all(from c in Conversation, where: c.user_id == ^user.id)
    for sandbox <- sandboxes, do: Repo.delete!(sandbox)
    Repo.delete!(user)
  end

  # ── retarget ──────────────────────────────────────────────────────────────

  describe "retarget" do
    test "moves the identity and records the skills", ctx do
      other_env = insert_env(user_id: ctx.user.id)

      assert {:ok, %Sandbox{} = moved} =
               Machine.retarget(
                 ctx.sandbox.id,
                 %{environment_id: other_env.id, applied_skills: [%{"name" => "x"}]},
                 conversation_id: ctx.conv.id
               )

      assert moved.environment_id == other_env.id
      assert moved.applied_skills == [%{"name" => "x"}]
    end

    test "refuses to move the identity of a machine a co-tenant shares", ctx do
      insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)
      other_env = insert_env(user_id: ctx.user.id)

      assert {:error, {:rebuild_required, :shared_sandbox}} =
               Machine.retarget(ctx.sandbox.id, %{environment_id: other_env.id},
                 conversation_id: ctx.conv.id
               )

      # The identity it already has is a refresh, and skills move no identity.
      assert {:ok, _} =
               Machine.retarget(ctx.sandbox.id, %{environment_id: ctx.env.id},
                 conversation_id: ctx.conv.id
               )

      assert {:ok, _} = Machine.retarget(ctx.sandbox.id, %{applied_skills: []})
    end

    test "a build fingerprint that is not the one expected is refused under the lock", ctx do
      stamp(ctx, build_fingerprint: "abc")

      assert {:error, {:rebuild_required, :environment}} =
               Machine.retarget(ctx.sandbox.id, %{vault_id: nil},
                 conversation_id: ctx.conv.id,
                 expected_fingerprint: "def"
               )

      assert {:ok, _} =
               Machine.retarget(ctx.sandbox.id, %{vault_id: nil},
                 conversation_id: ctx.conv.id,
                 expected_fingerprint: "abc"
               )
    end

    test "a terminal row, a missing one and a foreign field are refused", ctx do
      assert {:error, {:invalid, :status}} = Machine.retarget(ctx.sandbox.id, %{status: "ready"})
      assert {:error, {:invalid, :attrs}} = Machine.retarget(ctx.sandbox.id, %{})

      stamp(ctx, status: "terminated")

      assert {:error, :sandbox_unavailable} =
               Machine.retarget(ctx.sandbox.id, %{applied_skills: []})

      assert {:error, :sandbox_unavailable} =
               Machine.retarget(Ecto.UUID.generate(), %{applied_skills: []})
    end

    test "joins the caller's transaction, so a rollback takes the write with it", ctx do
      Repo.transaction(fn ->
        assert {:ok, _} = Machine.retarget(ctx.sandbox.id, %{applied_skills: [%{"name" => "x"}]})
        Repo.rollback(:undo)
      end)

      assert Repo.reload!(ctx.sandbox).applied_skills == nil
    end
  end

  # ── the Codex auth binding ────────────────────────────────────────────────

  describe "bind_inference" do
    test "requires the caller's transaction, and keeps a retired peer's binding", ctx do
      source = %Fountain.InferenceCredentials.Source{
        scope: "user",
        kind: "user",
        identity: "acct",
        revision: 1
      }

      codex = Repo.update!(Ecto.Changeset.change(ctx.conv, runtime: "codex"))

      assert {:error, :transaction_required} = Machine.bind_inference(codex, source)

      # A retired Codex peer with no binding still refuses: the machine keeps
      # its auth binding through a conversation's termination.
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: ctx.sandbox,
        status: "terminated",
        runtime: "codex"
      )

      Repo.transaction(fn ->
        assert {:error, :codex_inference_conflict} = Machine.bind_inference(codex, source)
      end)

      Repo.delete_all(
        from c in Conversation, where: c.sandbox_id == ^ctx.sandbox.id and c.id != ^codex.id
      )

      stamp(ctx, status: "pending")

      Repo.transaction(fn -> assert :ok = Machine.bind_inference(codex, source) end)
      assert Repo.reload!(ctx.sandbox).codex_inference_source["identity"] == "acct"
    end
  end

  # ── the owner ends the turns it operates over ─────────────────────────────

  describe "the turns the owner ends" do
    setup ctx do
      running = fn conv ->
        conv = conv |> Ecto.Changeset.change(status: "running") |> Repo.update!()

        {conv,
         insert_turn(conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})}
      end

      {conv, turn} = running.(ctx.conv)
      cotenant = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)
      {cotenant, cotenant_turn} = running.(cotenant)
      %{conv: conv, turn: turn, cotenant: cotenant, cotenant_turn: cotenant_turn}
    end

    test "a destroy ends every running turn bound to the machine, and leaves a rebound one",
         ctx do
      replacement = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

      rebound =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: replacement,
          status: "running"
        )

      rebound_turn =
        insert_turn(rebound, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})

      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      quietly(fn ->
        assert {:ok, :destroyed} =
                 Machine.destroy(ctx.sandbox.id,
                   actor: "system:sandbox_reaper",
                   reason: :reclaimed
                 )
      end)

      for turn <- [ctx.turn, ctx.cotenant_turn] do
        assert %Turn{status: "interrupted", orphaned_at: %DateTime{}} = Repo.reload!(turn)
      end

      assert Repo.reload!(ctx.conv).status == "idle"
      assert Repo.reload!(ctx.cotenant).status == "idle"
      assert Repo.reload!(rebound_turn).status == "running"

      assert [_, _] = stage_reasons("reattach", "interrupted", "machine_destroyed")

      assert [_, _] =
               Audit.list_for_user(ctx.user.id, action_prefix: "conversation.turn.orphaned")

      # And the recovering actor's later write finds the turn already ended.
      assert :noop =
               Machine.end_turn(ctx.turn, {:orphan, "attach_failed"}, sandbox_id: ctx.sandbox.id)
    end

    test "the replacement's destroy ends the predecessor's turn; the successor's write finds it ended",
         ctx do
      # Counterexample 3's real path: a wake builds a fresh machine and
      # retires the old row through the owner with `provider: :already_gone`.
      replacement = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

      # `provider: :already_gone` must cost no provider round trip, and that is
      # the whole claim here — so it is pinned by a stub that reports rather
      # than by `reject/1`, which this protocol rescues (see the moduledoc).
      test_pid = self()

      stub(Managoat.Sandbox, :destroy, fn _handle ->
        send(test_pid, :destroyed_at_provider)
        :ok
      end)

      quietly(fn ->
        assert {:ok, :destroyed} =
                 Fountain.Conversations.Termination._unsafe_destroy_machine(ctx.sandbox.id,
                   actor: "system:wake",
                   destroy_reason: :replaced,
                   reason: "sandbox_replaced",
                   terminating_conversation_id: nil,
                   provider: :already_gone
                 )
      end)

      refute_received :destroyed_at_provider

      assert Repo.reload!(ctx.turn).status == "interrupted"
      {:ok, _} = Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})

      assert :noop =
               Machine.end_turn(ctx.turn, {:orphan, "attach_failed"}, sandbox_id: replacement.id)
    end

    test "a ceiling park ends the requester's own turn before the stamp; an idle park refuses on it",
         ctx do
      # Alone on the machine: a co-tenant active inside the idle window is a
      # different veto (`busy_elsewhere?`), and not the one under test.
      Repo.delete_all(from t in Turn, where: t.conversation_id == ^ctx.cotenant.id)
      Repo.delete!(ctx.cotenant)
      opts = [actor: "system:conversation_server", requesting_conversation_id: ctx.conv.id]
      turn_id = ctx.turn.id

      # The instant the `parking` stamp lands, the turn is already terminal:
      # no reader ever sees `running` on a `parking` row. Observed on the
      # stamp's own statement — a plant that cuts the turn right *after* the
      # stamp still has it ended by the time the provider is asked, which is
      # why the suspend stub below is not enough on its own.
      stub(Managoat.Sandbox, :suspend, fn _ ->
        assert Repo.reload!(ctx.sandbox).transition == "parking"
        assert Repo.get!(Turn, turn_id).status == "interrupted"
        :ok
      end)

      test = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:fountain, :repo, :query],
        &__MODULE__.report_stamp/4,
        {test, turn_id}
      )

      try do
        quietly(fn ->
          assert {:error, :machine_occupied} = Park.run(ctx.sandbox.id, [reason: :idle] ++ opts)
          assert Repo.reload!(ctx.turn).status == "running"
          assert {:ok, :parked} = Park.run(ctx.sandbox.id, [reason: :max_lifetime] ++ opts)
        end)
      after
        :telemetry.detach(handler)
      end

      assert_received {:stamped, "interrupted"}

      assert %Turn{status: "interrupted", orphaned_at: %DateTime{}} = Repo.reload!(ctx.turn)
      assert Repo.reload!(ctx.conv).status == "idle"
      assert [_] = stage_reasons("reattach", "interrupted", "machine_parked")
    end

    test "the server ending the same turn is a :noop in either order, with one event", ctx do
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      Repo.delete_all(from t in Turn, where: t.conversation_id == ^ctx.cotenant.id)
      Repo.delete!(ctx.cotenant)
      opts = [actor: "system:conversation_server", requesting_conversation_id: ctx.conv.id]

      orphaned = fn ->
        Audit.list_for_user(ctx.user.id, action_prefix: "conversation.turn.orphaned")
      end

      # Owner first: the park ended it; the server's own ending on its way out
      # writes nothing and records nothing.
      quietly(fn ->
        assert {:ok, :parked} = Park.run(ctx.sandbox.id, [reason: :max_lifetime] ++ opts)
      end)

      assert [_] = orphaned.()

      assert :noop = Machine.end_turn(ctx.turn, :mark_interrupted, sandbox_id: ctx.sandbox.id)

      assert :noop =
               Machine.end_turn(ctx.turn, {:orphan, "server_terminated_normally"},
                 sandbox_id: ctx.sandbox.id
               )

      assert [_] = orphaned.()
      assert Repo.reload!(ctx.turn).status == "interrupted"

      # Server first: the turn is already terminal when the park cuts, and the
      # park's ending is not this owner's — nothing written, nothing recorded.
      stamp(ctx, status: "ready")
      {:ok, _} = Conversations.update_conversation(Repo.reload!(ctx.conv), %{status: "running"})

      second =
        insert_turn(ctx.conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})

      assert {:ok, %Turn{status: "interrupted"}} =
               Machine.end_turn(second, :mark_interrupted, sandbox_id: ctx.sandbox.id)

      quietly(fn ->
        assert {:ok, :parked} = Park.run(ctx.sandbox.id, [reason: :max_lifetime] ++ opts)
      end)

      assert Repo.reload!(second).status == "interrupted"
      assert is_nil(Repo.reload!(second).orphaned_at)
      assert [_] = orphaned.()
    end

    test "a park over a turn nothing is driving leaves it standing (stage 6b's rule)", ctx do
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      Repo.delete_all(from t in Turn, where: t.conversation_id == ^ctx.cotenant.id)

      quietly(fn ->
        assert {:ok, :parked} =
                 Park.run(ctx.sandbox.id, actor: "system:sandbox_reaper", reason: :idle)
      end)

      assert Repo.reload!(ctx.turn).status == "running"
      assert Repo.reload!(ctx.conv).status == "running"
    end

    test "end_turns_on/3 is best effort per turn, and narrows to one conversation", ctx do
      # A turn already ended by its actor is not this owner's to end, and the
      # next one is still ended; `:only` leaves every other conversation alone.
      assert {:ok, _} =
               Machine.end_turn(ctx.cotenant_turn, {:finish, "completed", []},
                 sandbox_id: ctx.sandbox.id
               )

      quietly(fn ->
        assert :ok =
                 Admission.end_turns_on(ctx.sandbox.id, "machine_destroyed",
                   only: ctx.cotenant.id,
                   actor: "system:sandbox_reaper"
                 )
      end)

      assert Repo.reload!(ctx.turn).status == "running"

      quietly(fn ->
        assert :ok =
                 Admission.end_turns_on(ctx.sandbox.id, "machine_destroyed",
                   actor: "system:sandbox_reaper"
                 )
      end)

      assert Repo.reload!(ctx.turn).status == "interrupted"
      assert Repo.reload!(ctx.cotenant_turn).status == "completed"
    end
  end

  # ── machine_gone, sent by the owner ───────────────────────────────────────

  describe "the machine-gone cast" do
    test "a replaced machine's co-tenants are told by the owner's destroy, each group its own notice",
         ctx do
      following =
        insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)

      stranded = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)
      stand_in_server(following.id)
      stand_in_server(stranded.id)

      quietly(fn ->
        assert {:ok, :destroyed} =
                 Destroy.run(ctx.sandbox.id,
                   actor: "system:wake",
                   reason: :replaced,
                   terminating_conversation_id: nil,
                   provider: :already_gone,
                   notify: [
                     {[following.id], "replaced", "sprite_gone", "moved"},
                     {[stranded.id], "reset", "sprite_gone", "stays"}
                   ]
                 )
      end)

      sandbox_id = ctx.sandbox.id
      following_id = following.id
      stranded_id = stranded.id

      assert_receive {:cotenant, ^following_id,
                      {:"$gen_cast",
                       {:machine_gone, ^sandbox_id, "replaced", "sprite_gone", "moved"}}},
                     2_000

      assert_receive {:cotenant, ^stranded_id,
                      {:"$gen_cast",
                       {:machine_gone, ^sandbox_id, "reset", "sprite_gone", "stays"}}},
                     2_000

      # Once each. The stand-in forwards every message, so a second notice
      # would be here to find — which is the half of this that the duplicate
      # found in round 1 needed and the one-message receiver could not give.
      # `wake_cotenants_test.exs` drives the same count through a real wake;
      # this one drives it through `Destroy.run/2`'s `:notify` directly.
      refute_receive {:cotenant, _, {:"$gen_cast", {:machine_gone, _, _, _, _}}}, 500
    end
  end

  # ── a message shape this release has no clause for ────────────────────────

  describe "an owner asked something it has no clause for" do
    test "refuses the caller and keeps its mailbox, on all three callbacks", ctx do
      # ADR 0058 rule 4, from the other side. An old owner meeting a new
      # release's message dies with everything queued behind it — which is what
      # 8b's own three new shapes do to an owner on the previous release, and
      # why the mixed-version note says so. From here on, the cost of that
      # rollout is one 503 to one caller.
      #
      # All three callbacks, because all three had the hole: a missing call
      # clause raises, a missing cast clause is `{:bad_cast, ..}` from
      # `GenServer`'s generated one, and defining any `handle_info/2` replaces
      # the default that would have logged and ignored — so a stray `:DOWN` or
      # a late reply took the owner down too.
      # A payload that would be unmistakable in a log line if the redaction
      # leaked: empty values prove nothing (round 3, behaviour review drove the
      # refutation with a string of its own for the same reason).
      secret = "sk-live-do-not-log-me-9f3c"

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        sandbox_id = ctx.sandbox.id

        call_log =
          capture_log(fn ->
            assert {:error, :sandbox_unavailable} =
                     GenServer.call(owner, {:a_verb_from_a_later_release, %{token: secret}, nil})
          end)

        # The log has to name what arrived and on which machine, or this
        # clause is silence with a return value (the lead's condition). The
        # call returning at all is the proof the owner survived, so there is no
        # `Process.alive?` here; the barrier calls below are the same proof for
        # the two asynchronous cases.
        assert call_log =~ "no handle_call clause for :a_verb_from_a_later_release/3"
        assert call_log =~ sandbox_id

        cast_log =
          capture_log(fn ->
            GenServer.cast(owner, {:a_cast_from_a_later_release, %{token: secret}})
            # The cast is asynchronous; this call is the barrier that forces
            # the owner to have handled it.
            assert %Fountain.Machines.Occupancy{} = GenServer.call(owner, :who_is_here)
          end)

        assert cast_log =~ "no handle_cast clause for :a_cast_from_a_later_release/2"
        assert cast_log =~ sandbox_id

        info_log =
          capture_log(fn ->
            send(owner, {:DOWN, make_ref(), :process, self(), :normal})
            assert %Fountain.Machines.Occupancy{} = GenServer.call(owner, :who_is_here)
          end)

        assert info_log =~ "unexpected message :DOWN/5"
        assert info_log =~ sandbox_id

        # **And a message that is not a tuple**, which is where the redaction
        # claim used to be false: the fallback inspected the whole term, so a
        # map or a binary went into the log entire. The type, and nothing else.
        map_log =
          capture_log(fn ->
            send(owner, %{token: secret})
            assert %Fountain.Machines.Occupancy{} = GenServer.call(owner, :who_is_here)
          end)

        assert map_log =~ "unexpected message a map"

        # The payload never reaches the log, whatever its shape: a tuple is a
        # tag and an arity, anything else is a type.
        for log <- [call_log, cast_log, info_log, map_log] do
          refute log =~ secret
        end

        # And it still answers the verbs it does know.
        assert %Fountain.Machines.Occupancy{} = GenServer.call(owner, :who_is_here)
      end)
    end
  end

  # ── the early takeover of a lease whose node is gone ──────────────────────

  describe "a lease held by a node that is not connected" do
    test "is taken once it has run down past the headroom, with a log line", ctx do
      stamp(ctx,
        lease_epoch: 4,
        lease_node: "dead-pod@nowhere",
        lease_until: DateTime.add(DateTime.utc_now(), 5, :second)
      )

      log =
        capture_log(fn ->
          assert {:ok, 5} = Lease.claim(ctx.sandbox.id, "reaper@node", 60_000)
        end)

      assert log =~ "is not a connected node and had stopped renewing"
      assert Repo.reload!(ctx.sandbox).lease_node == "reaper@node"
    end

    test "is held while it is still being renewed — a partitioned node that is alive", ctx do
      # Driven at the line, not near it (round 1). A live renewer of the
      # shortest TTL stands at one whole renew interval when a single renewal
      # has been missed, which is where the round-1 probe's holder was when the
      # old headroom took its machine 40 s early; the 50 s plant this test used
      # to carry never came within 30 s of the rule it was pinning.
      renew_interval = div(Destroy.lease_ttl_ms(), Renewal.divisor())

      for remaining_ms <- [50_000, renew_interval, Lease.absent_node_headroom_ms() + 1_000] do
        stamp(ctx,
          lease_epoch: 4,
          lease_node: "partitioned-pod@elsewhere",
          lease_until: DateTime.add(DateTime.utc_now(), remaining_ms, :millisecond)
        )

        assert {:error, {:held, "partitioned-pod@elsewhere", _}} =
                 Lease.claim(ctx.sandbox.id, "reaper@node", 60_000),
               "a holder with #{remaining_ms} ms of lease left was taken over early"
      end
    end

    test "this node's own lease is never taken early", ctx do
      stamp(ctx,
        lease_epoch: 4,
        lease_node: to_string(node()),
        lease_until: DateTime.add(DateTime.utc_now(), 5, :second)
      )

      holder = to_string(node())
      assert {:error, {:held, ^holder, _}} = Lease.claim(ctx.sandbox.id, "reaper@node", 60_000)
    end

    test "the protocol that takes it re-checks under its new lease", ctx do
      # A destroy that lands on such a lease and finds a fence already there
      # and the row terminal answers for the row, not the dead holder.
      stamp(ctx,
        lease_epoch: 4,
        lease_node: "dead-pod@nowhere",
        lease_until: DateTime.add(DateTime.utc_now(), 5, :second),
        transition: "destroying",
        status: "terminated"
      )

      quietly(fn ->
        assert {:ok, :already_terminal} =
                 Machine.destroy(ctx.sandbox.id,
                   actor: "system:sandbox_reaper",
                   reason: :reclaimed
                 )
      end)

      assert is_nil(Repo.reload!(ctx.sandbox).transition)
    end
  end

  # ── a late resume ─────────────────────────────────────────────────────────

  describe "ensure_up carries the caller's deadline (gate on)" do
    test "a resume whose caller has given up is refused, not run late", ctx do
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(700)
        :ok
      end)

      # A stub that answers, not a `reject`: a rejected call raises inside the
      # protocol, which rescues it as a failed resume and leaves the row
      # `suspended` — the very state this test asserts — so a plant that turns
      # the deadline off stayed green against it. The provider's own word is
      # what the assertion has to see.
      stub(Managoat.Sandbox, :resume, fn handle ->
        send(test, :resumed_at_provider)
        {:ok, handle}
      end)

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Managoat.Sandbox, self(), owner)
        sandbox_id = ctx.sandbox.id

        park =
          Task.async(fn ->
            capture_log(fn ->
              send(
                test,
                {:park, Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)}
              )
            end)
          end)

        assert_receive :suspending, 2_000

        quietly(fn ->
          assert {:error, :sandbox_unavailable} =
                   Machine.ensure_up(ctx.sandbox.id, actor: "system:wake", resume_timeout_ms: 200)
        end)

        assert_receive {:park, {:ok, :parked}}, 5_000
        Task.await(park)
        assert %Fountain.Machines.Occupancy{} = Machine.who_is_here(ctx.sandbox.id)
      end)

      refute_received :resumed_at_provider, "the owner resumed a machine for nobody"
      assert Repo.reload!(ctx.sandbox).status == "suspended"
    end

    test "and a caller still waiting when the park finishes is answered (the positive control)",
         ctx do
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(300)
        :ok
      end)

      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Managoat.Sandbox, self(), owner)
        sandbox_id = ctx.sandbox.id

        park =
          Task.async(fn ->
            capture_log(fn ->
              send(
                test,
                {:park, Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)}
              )
            end)
          end)

        assert_receive :suspending, 2_000

        quietly(fn ->
          assert {:ok, :resumed} =
                   Machine.ensure_up(ctx.sandbox.id,
                     actor: "system:wake",
                     resume_timeout_ms: 5_000
                   )
        end)

        assert_receive {:park, {:ok, :parked}}, 5_000
        Task.await(park)
      end)

      assert Repo.reload!(ctx.sandbox).status == "ready"
    end

    test "a message from a caller on the previous release still runs", ctx do
      stamp(ctx, status: "suspended")
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Managoat.Sandbox, self(), owner)

        quietly(fn ->
          assert {:ok, :resumed} = GenServer.call(owner, {:ensure_up, [actor: "system:wake"]})
        end)
      end)

      assert Repo.reload!(ctx.sandbox).status == "ready"
    end
  end

  # ── the reaper's stuck pass ───────────────────────────────────────────────

  describe "release_stuck_sandboxes/0" do
    test "one refused write does not stop the pass", ctx do
      cutoff = DateTime.add(DateTime.utc_now(), -120 * 60, :second)

      stuck =
        for _ <- 1..2 do
          sandbox =
            insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "pending")

          Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
            set: [updated_at: cutoff]
          )

          sandbox
        end

      [refused, released] = stuck
      refused_id = refused.id

      stub(Conversations, :update_sandbox, fn
        %Sandbox{id: ^refused_id}, _attrs -> {:error, :boom}
        sandbox, attrs -> sandbox |> Sandbox.changeset(attrs) |> Repo.update()
      end)

      log =
        capture_log(fn ->
          assert Fountain.Workers.SandboxReaper.release_stuck_sandboxes() == 1
        end)

      assert log =~ "could not release stuck sandbox #{refused.id}"
      assert Repo.reload!(refused).status == "pending"
      assert Repo.reload!(released).status == "failed"
    end
  end
end
