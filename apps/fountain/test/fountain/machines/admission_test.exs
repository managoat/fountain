defmodule Fountain.Machines.AdmissionTest do
  @moduledoc """
  The turn-admission protocol (ADR 0058 stage 8a).

  What these pin is what the owner decides **under the lock** that `main` did
  not: a live lease refuses the turn, either fence refuses it, and capacity is
  the runtime's. The per-runtime count itself has its cases in
  `shared_sandbox_test.exs`, beside the context write they exercise; this file
  is the protocol, the two doors, the fence they share, and the one race the
  whole ADR exists for — an admission and a park of the same machine, on real
  connections, in both orders (the #2286 shape).

  `async: false`: the gate is application environment, the gate-on cases run
  the protocol inside an owner process that needs the shared sandbox
  connection, and the race cases use `unboxed_run`.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Sandbox, Turn}
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Park

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "opencode")
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp attrs(conv, n \\ 1) do
    %{
      conversation_id: conv.id,
      turn_number: n,
      prompt: "hi",
      status: "running",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp turns(conv), do: Conversations._unsafe_list_turns(conv.id)

  defp stamp(ctx, sets) do
    Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id), set: sets)
  end

  # The row an owner leaves when it dies mid-operation: a stamp under a lease
  # that has lapsed. Stage 6a's rule is that this refuses nobody.
  defp abandon(ctx, transition) do
    stamp(ctx,
      lease_epoch: 1,
      lease_node: "dead-pod@node",
      lease_until: DateTime.add(DateTime.utc_now(), -60, :second),
      transition: transition,
      transition_reason: "idle"
    )
  end

  defp quietly(fun), do: capture_log(fun)

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
  # asks the registry. Same shape as `park_test.exs`. A park counts a running
  # turn as occupancy only when something is driving it, so the race below
  # needs one.
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

    # The registry is a CRDT; the registration is visible only after it has
    # propagated to this node's view of it.
    wait_until(fn ->
      Fountain.Conversations.ConversationServer.whereis(conversation_id) == pid
    end)

    pid
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  # ── what the lock decides ─────────────────────────────────────────────────

  describe "a live lease" do
    test "refuses the turn, after waiting for it", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, "other@node", 60_000)
      started = System.monotonic_time(:millisecond)

      log =
        quietly(fn ->
          assert {:error, :machine_busy} =
                   Admission.run(ctx.sandbox.id, attrs(ctx.conv), busy_wait_ms: 600)
        end)

      waited = System.monotonic_time(:millisecond) - started
      assert log =~ "admission refused"
      assert waited >= 250, "the wait gave up without waiting at all"
      assert waited < 5_000, "the wait ran past the bound it was given"
      assert turns(ctx.conv) == []
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "that clears inside the wait admits the turn", ctx do
      {:ok, epoch} = Lease.claim(ctx.sandbox.id, "other@node", 60_000)
      sandbox_id = ctx.sandbox.id

      # The holder finishes its operation while the prompt is waiting — a
      # cotenant's resume, in the common case.
      releaser =
        Task.async(fn ->
          Process.sleep(400)
          :ok = Lease.release(sandbox_id, epoch)
        end)

      started = System.monotonic_time(:millisecond)
      assert {:ok, %Turn{status: "running"}} = Admission.run(sandbox_id, attrs(ctx.conv))
      waited = System.monotonic_time(:millisecond) - started

      assert waited >= 250, "the turn was admitted under a live lease"
      Task.await(releaser)
      assert Repo.reload!(ctx.conv).status == "running"
    end

    test "is judged on the database's clock: a lapsed one refuses nothing", ctx do
      stamp(ctx,
        lease_epoch: 3,
        lease_node: "dead-pod@node",
        lease_until: DateTime.add(DateTime.utc_now(), -1, :second)
      )

      assert {:ok, _turn} = Admission.run(ctx.sandbox.id, attrs(ctx.conv))
    end

    for transition <- ~w(parking resuming destroying provisioning) do
      test "an abandoned #{transition} stamp refuses nothing (stage 6a's rule)", ctx do
        abandon(ctx, unquote(transition))
        assert {:ok, _turn} = Admission.run(ctx.sandbox.id, attrs(ctx.conv))
      end
    end
  end

  describe "the fences" do
    test "a teardown fence refuses the turn, where main admitted it", ctx do
      stamp(ctx, teardown_requested_at: DateTime.utc_now())

      assert {:error, :sandbox_unavailable} = Admission.run(ctx.sandbox.id, attrs(ctx.conv))
      assert turns(ctx.conv) == []
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "a reset fence refuses the turn, as it always has", ctx do
      stamp(ctx, reset_requested_at: DateTime.utc_now())

      assert {:error, :sandbox_unavailable} = Admission.run(ctx.sandbox.id, attrs(ctx.conv))
      assert turns(ctx.conv) == []
    end

    test "a fence is judged before the lease, so it is final rather than waited out", ctx do
      stamp(ctx, teardown_requested_at: DateTime.utc_now())
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, "other@node", 60_000)
      started = System.monotonic_time(:millisecond)

      assert {:error, :sandbox_unavailable} =
               Admission.run(ctx.sandbox.id, attrs(ctx.conv), busy_wait_ms: 2_000)

      assert System.monotonic_time(:millisecond) - started < 1_000,
             "a final refusal was waited on as though the lease could clear it"
    end
  end

  describe "the write's own words travel" do
    test "capacity, the revision and a terminal machine are the caller's vocabulary", ctx do
      other = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)
      insert_turn(other, %{status: "running", prompt: "busy", started_at: DateTime.utc_now()})

      assert {:error, :sandbox_at_capacity} = Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv))

      Repo.delete_all(from t in Turn, where: t.conversation_id == ^other.id)

      assert {:error, :configuration_changed} =
               Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv), revision: 999)

      ctx.sandbox |> Ecto.Changeset.change(status: "terminated") |> Repo.update!()
      assert {:error, :sandbox_unavailable} = Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv))
    end

    test "the runtime's bound is read from the row, not brought by the caller", ctx do
      # `insert_conversation/1` snapshots the agent's runtime; the row is what
      # the locked insert reads, so switching it switches the bound.
      other = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)
      insert_turn(other, %{status: "running", prompt: "busy", started_at: DateTime.utc_now()})

      assert {:error, :sandbox_at_capacity} = Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv))

      ctx.conv |> Ecto.Changeset.change(runtime: "claude") |> Repo.update!()
      assert {:ok, _turn} = Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv))
    end
  end

  # ── the door ──────────────────────────────────────────────────────────────

  describe "Machine.admit_turn/3" do
    test "translates a live lease into the word the system has", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, "other@node", 60_000)

      quietly(fn ->
        assert {:error, :sandbox_unavailable} =
                 Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv), busy_wait_ms: 100)
      end)
    end

    test "refuses an enclosing transaction at the door and in the protocol", ctx do
      Repo.transaction(fn ->
        assert {:error, :provider_transaction_open} =
                 Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv))

        assert {:error, :transaction_open} = Admission.run(ctx.sandbox.id, attrs(ctx.conv))
      end)

      assert turns(ctx.conv) == []
    end

    for gate <- [false, true] do
      test "inline and in-owner admit the same way (gate #{gate})", ctx do
        with_gate(unquote(gate), fn ->
          assert {:ok, %Turn{status: "running"} = turn} =
                   Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv))

          assert turn.conversation_id == ctx.conv.id
          assert Machine.whereis(ctx.sandbox.id) != nil == unquote(gate)
        end)

        assert Repo.reload!(ctx.conv).status == "running"
        assert [%Turn{status: "running"}] = turns(ctx.conv)
      end
    end

    test "with the gate on, the owner survives to answer again", ctx do
      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        assert {:ok, _turn} = Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv))
        assert Machine.whereis(ctx.sandbox.id) == owner
      end)
    end

    test "an owner that cannot run the admission refuses rather than admitting inline", ctx do
      # The mixed-version shape: with the gate on, a `{:admit_turn, ..}` call
      # reaching an owner process that cannot serve it — a replica on the
      # previous release has no clause for it and crashes — has to come back
      # as a refusal, not as a turn admitted somewhere else. A raise inside
      # the owner is the same exit the caller sees in that case.
      with_gate(true, fn ->
        {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
        Mimic.allow(Admission, self(), owner)

        stub(Admission, :run, fn _id, _attrs, _opts -> raise "no clause for {:admit_turn, ..}" end)

        quietly(fn ->
          assert {:error, :sandbox_unavailable} =
                   Machine.admit_turn(ctx.sandbox.id, attrs(ctx.conv))
        end)
      end)

      assert turns(ctx.conv) == []
      assert Repo.reload!(ctx.conv).status == "idle"
    end
  end

  # ── the race (#2286) ──────────────────────────────────────────────────────

  describe "an admission and a park of one machine, on real connections" do
    # Both orders, and the park from both of its callers: the reaper's sweep
    # (no requester) and a co-tenant server's idle tick (a requester that is
    # not the admitted conversation). The admission holds the per-sandbox
    # advisory lock for the length of its transaction; `Lease.claim/4` takes the
    # same lock, so whichever arrives second waits on PostgreSQL and then reads
    # what the first committed.
    for requester <- [:sweep, :cotenant_server] do
      @tag requester: requester
      test "admission first: the park waits on the lock, then refuses (#{requester})", ctx do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          user = insert_verified_user()
          agent = insert_agent(user_id: user.id, runtime: "opencode")
          sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

          conv =
            insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

          cotenant =
            insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

          stand_in_server(conv.id)
          owner = self()
          handler = {__MODULE__, make_ref()}

          :telemetry.attach(
            handler,
            [:fountain, :repo, :query],
            &__MODULE__.pause_admission/4,
            owner
          )

          park_opts =
            case ctx.requester do
              :sweep ->
                [actor: "system:sandbox_reaper", reason: :idle]

              :cotenant_server ->
                [actor: "self", reason: :idle, requesting_conversation_id: cotenant.id]
            end

          admission =
            independent(fn ->
              Process.put(:pause_admission_test, true)
              Admission.run(sandbox.id, attrs(conv))
            end)

          try do
            assert_receive :turn_inserted, 5_000

            park =
              independent(fn ->
                reject(&Managoat.Sandbox.suspend/1)
                capture_log(fn -> send(owner, {:park, Park.run(sandbox.id, park_opts)}) end)
              end)

            try do
              park_pid = park.pid
              assert_receive {:backend, ^park_pid, park_backend}, 5_000
              # The park's claim is waiting on the admission's advisory lock.
              await_blocked(park_backend, System.monotonic_time(:millisecond) + 5_000)
              assert Task.yield(park, 0) == nil

              send(admission.pid, :commit)
              assert {:ok, %Turn{status: "running"}} = Task.await(admission)

              # The park now reads the committed turn, with a server driving it.
              assert_receive {:park, {:error, :machine_occupied}}, 5_000
              Task.await(park)
              assert Repo.reload!(sandbox).status == "ready"
              assert is_nil(Repo.reload!(sandbox).lease_node)
            after
              Task.shutdown(park, :brutal_kill)
            end
          after
            Task.shutdown(admission, :brutal_kill)
            :telemetry.detach(handler)
            discard(user, [sandbox])
          end
        end)
      end
    end

    test "park first: the admission waits on the lease, then refuses", ctx do
      # The other order needs no second connection: the park's lease outlives
      # its claim transaction, which is the whole point of a lease, and the
      # admission reads it under the lock it then takes.
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id, "reaper@node", 60_000)

      quietly(fn ->
        assert {:error, :machine_busy} =
                 Admission.run(ctx.sandbox.id, attrs(ctx.conv), busy_wait_ms: 300)
      end)

      assert turns(ctx.conv) == []
    end

    test "park first, on the lock itself: the admission waits on PostgreSQL", _ctx do
      # A park whose claim transaction is still open holds 4316, not yet a
      # lease. The admission blocks on the lock — observed with
      # `pg_blocking_pids` — and reads the lease the moment it is committed.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        agent = insert_agent(user_id: user.id, runtime: "opencode")
        sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

        conv =
          insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

        owner = self()

        holder =
          independent(fn ->
            Conversations.with_sandbox_lock(sandbox.id, fn ->
              send(owner, :lock_held)

              receive do
                :commit -> {:ok, :ok}
              after
                10_000 -> raise "lock release timed out"
              end
            end)
          end)

        try do
          assert_receive :lock_held, 5_000

          admission =
            independent(fn ->
              capture_log(fn ->
                send(
                  owner,
                  {:admission, Admission.run(sandbox.id, attrs(conv), busy_wait_ms: 200)}
                )
              end)
            end)

          try do
            admission_pid = admission.pid
            assert_receive {:backend, ^admission_pid, backend}, 5_000
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)

            # The holder becomes a lease and commits; the admission then sees
            # it under the lock it was waiting for.
            {:ok, _} =
              Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
                set: [
                  lease_epoch: 1,
                  lease_node: "reaper@node",
                  lease_until: DateTime.add(DateTime.utc_now(), 60, :second)
                ]
              )
              |> then(fn {1, _} -> {:ok, :ok} end)

            send(holder.pid, :commit)
            assert {:ok, :ok} = Task.await(holder)
            assert_receive {:admission, {:error, :machine_busy}}, 5_000
            Task.await(admission)
            assert Repo.all(from t in Turn, where: t.conversation_id == ^conv.id) == []
          after
            Task.shutdown(admission, :brutal_kill)
          end
        after
          Task.shutdown(holder, :brutal_kill)
          discard(user, [sandbox])
        end
      end)
    end
  end

  def pause_admission(_event, _measurements, metadata, owner) do
    if Process.get(:pause_admission_test) &&
         String.starts_with?(metadata.query, ~s(INSERT INTO "turns")) do
      Process.delete(:pause_admission_test)
      send(owner, :turn_inserted)

      receive do
        :commit -> :ok
      after
        10_000 -> raise "admission release timed out"
      end
    end
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

  # `unboxed_run` commits, so the rows a race case makes are removed by hand,
  # audit and usage included.
  defp discard(user, sandboxes) do
    Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
    Repo.delete_all(from e in Fountain.Billing.UsageEvent, where: e.user_id == ^user.id)
    Repo.delete_all(from c in Conversation, where: c.user_id == ^user.id)
    for sandbox <- sandboxes, do: Repo.delete!(sandbox)
    Repo.delete!(user)
  end

  # ── end_turn ──────────────────────────────────────────────────────────────

  describe "Machine.end_turn/3" do
    setup ctx do
      conv = ctx.conv |> Ecto.Changeset.change(status: "running") |> Repo.update!()
      turn = insert_turn(conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})
      replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
      %{conv: conv, turn: turn, replacement: replacement}
    end

    test "a bound actor finishes, interrupts and orphans its turn", ctx do
      assert {:ok, %Turn{status: "completed"}} =
               Machine.end_turn(ctx.turn, {:finish, "completed", []}, sandbox_id: ctx.sandbox.id)

      assert Repo.reload!(ctx.conv).status == "idle"

      second =
        insert_turn(ctx.conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})

      # Reloaded: the struct in `ctx` still says `running` from the setup, and a
      # changeset built on it would have nothing to write.
      {:ok, _} = Conversations.update_conversation(Repo.reload!(ctx.conv), %{status: "running"})
      assert Repo.reload!(ctx.conv).status == "running"

      assert {:ok, %Turn{status: "interrupted"}} =
               Machine.end_turn(second, :mark_interrupted, sandbox_id: ctx.sandbox.id)

      # The two-phase interrupt's first half leaves the parent running.
      assert Repo.reload!(ctx.conv).status == "running"

      third =
        insert_turn(ctx.conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})

      assert {:ok, %Turn{status: "interrupted", orphaned_at: %DateTime{}}, %Conversation{}} =
               Machine.end_turn(third, {:orphan, "server_terminated_normally"},
                 sandbox_id: ctx.sandbox.id
               )

      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "a stale actor writes nothing on any of the three endings", ctx do
      {:ok, _} = Conversations.update_conversation(ctx.conv, %{sandbox_id: ctx.replacement.id})

      assert :noop =
               Machine.end_turn(ctx.turn, {:finish, "completed", []}, sandbox_id: ctx.sandbox.id)

      assert :noop = Machine.end_turn(ctx.turn, :mark_interrupted, sandbox_id: ctx.sandbox.id)

      assert {:error, :ownership_changed} =
               Machine.end_turn(ctx.turn, {:orphan, "attach_failed"}, sandbox_id: ctx.sandbox.id)

      assert Repo.reload!(ctx.turn).status == "running"
      assert is_nil(Repo.reload!(ctx.turn).orphaned_at)
      assert Repo.reload!(ctx.conv).status == "running"
    end

    test "a recovery on nobody's behalf omits the binding; an explicit nil is one", ctx do
      assert {:error, :ownership_changed} =
               Machine.end_turn(ctx.turn, {:orphan, "unbound_actor"}, sandbox_id: nil)

      assert Repo.reload!(ctx.turn).status == "running"

      assert {:ok, %Turn{status: "interrupted"}, _conv} =
               Machine.end_turn(ctx.turn, {:orphan, "stuck_running_no_server"},
                 actor: "system:autonomous_turn_reaper"
               )
    end

    test "an actor's ending without a binding is a caller bug, not a write", ctx do
      assert_raise KeyError, fn -> Machine.end_turn(ctx.turn, {:finish, "completed", []}, []) end
      assert_raise KeyError, fn -> Machine.end_turn(ctx.turn, :mark_interrupted, []) end
      assert Repo.reload!(ctx.turn).status == "running"
    end

    test "bound?/2 is the binding, now", ctx do
      assert Admission.bound?(Repo.reload!(ctx.conv), ctx.sandbox.id)
      refute Admission.bound?(Repo.reload!(ctx.conv), ctx.replacement.id)
      refute Admission.bound?(Repo.reload!(ctx.conv), nil)
      assert Admission.bound?(%{sandbox_id: nil}, nil)
    end
  end

  # ── why the fence is the binding, not the machine's epoch ─────────────────

  describe "the fence is the conversation's binding (ADR 0058 stage 8a)" do
    # Three writes that must land, each on a path where the machine's lease
    # epoch has moved out from under the turn or the turn was admitted on
    # another machine. Whoever later tightens the fence to the epoch — which
    # waits on the owner ending the turns it operates over, stage 8b — has to
    # break one of these by name rather than re-derive the argument.

    setup ctx do
      conv = ctx.conv |> Ecto.Changeset.change(status: "running") |> Repo.update!()
      turn = insert_turn(conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})
      %{conv: conv, turn: turn}
    end

    test "a cotenant's operation moves the machine's epoch under a running turn; the turn still ends",
         ctx do
      # A cotenant's resume, park or destroy claims and releases the lease,
      # which is what moves the epoch. Done directly: the epoch moving is the
      # whole of what those operations do to this write's view of the machine.
      epoch_before = Repo.reload!(ctx.sandbox).lease_epoch
      {:ok, epoch} = Lease.claim(ctx.sandbox.id, "cotenant@node", 60_000)
      :ok = Lease.release(ctx.sandbox.id, epoch)
      assert Repo.reload!(ctx.sandbox).lease_epoch > epoch_before

      assert {:ok, %Turn{status: "completed"}} =
               Machine.end_turn(ctx.turn, {:finish, "completed", []}, sandbox_id: ctx.sandbox.id)

      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "a park over a turn nothing is driving moves the epoch; the reattaching server still orphans it",
         ctx do
      # Stage 6b's rule: a running turn with no live server is not occupancy,
      # so the reaper parks the machine. The server that later comes back and
      # cannot attach to the turn's session is the write that has to land.
      assert Fountain.Conversations.ConversationServer.whereis(ctx.conv.id) == nil
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      epoch_before = Repo.reload!(ctx.sandbox).lease_epoch

      quietly(fn ->
        assert {:ok, :parked} =
                 Park.run(ctx.sandbox.id, actor: "system:sandbox_reaper", reason: :idle)
      end)

      assert Repo.reload!(ctx.sandbox).status == "suspended"
      assert Repo.reload!(ctx.sandbox).lease_epoch > epoch_before

      assert {:ok, %Turn{status: "interrupted", orphaned_at: %DateTime{}}, _conv} =
               Machine.end_turn(ctx.turn, {:orphan, "attach_failed"}, sandbox_id: ctx.sandbox.id)

      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "the successor on the replacement machine ends the predecessor's turn", ctx do
      # The turn was admitted on the old machine; a wake built a fresh one and
      # the server on it is the one that has to close the turn — and
      # `AutonomousTurnReaper` never would, because a server is registered.
      replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
      {:ok, _} = Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})

      assert {:ok, %Turn{status: "interrupted"}, _conv} =
               Machine.end_turn(ctx.turn, {:orphan, "attach_failed"}, sandbox_id: replacement.id)

      assert Repo.reload!(ctx.conv).status == "idle"

      # And the actor on the old machine, for the same turn, writes nothing.
      second =
        insert_turn(ctx.conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})

      assert {:error, :ownership_changed} =
               Machine.end_turn(second, {:orphan, "attach_failed"}, sandbox_id: ctx.sandbox.id)
    end
  end
end
