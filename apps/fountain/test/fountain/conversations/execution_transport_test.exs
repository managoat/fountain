defmodule Fountain.Conversations.ExecutionTransportTest do
  use Fountain.DataCase, async: false
  use Mimic

  setup :set_mimic_global

  alias Fountain.Conversations.{ExecutionGuard, ExecutionTransport, Turn, TurnExecution}
  alias Managoat.Sandbox
  alias Managoat.Sandbox.{Command, Handle}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    now = DateTime.utc_now()
    turn = insert_turn(conv, status: "running", started_at: DateTime.truncate(now, :second))
    %{conv: conv, turn: turn, sandbox: sandbox, now: now}
  end

  defp register(c) do
    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        c.turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60, :second)
      )

    execution
  end

  defp launch(execution, behavior, opts \\ []) do
    test = self()
    name = execution.sandbox_name
    ref = make_ref()
    command = %Command{provider: :sprites, ref: ref}

    expect(Sandbox, :build_handle, fn :sprites, ^name ->
      %Handle{provider: :sprites, name: name}
    end)

    expect(Sandbox, :spawn, fn %Handle{name: ^name}, "acp", [], spawn_opts ->
      transport = Keyword.fetch!(spawn_opts, :owner)
      assert spawn_opts[:session_info] == true
      assert spawn_opts[:stdin] == true
      assert spawn_opts[:detachable] == true
      send(test, {:spawn, transport, ref, self()})
      behavior.(transport, ref)
      {:ok, command}
    end)

    owner = Keyword.get(opts, :actor, self())
    {:ok, pid} = ExecutionTransport._unsafe_start(execution.id, owner, "acp", [], opts)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Fountain.ExecutionTransportSupervisor, pid)
    end)

    {pid, ref}
  end

  defp timeout_task(task) do
    # Deliver the same untrappable exit as :timer.kill_after/1, but only once
    # the operation under test has reached its blocking provider call.
    ref = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 5_000
  end

  defp identify(owner, ref), do: send(owner, {:session_info, %{ref: ref}, "19"})
  defp row(execution), do: Repo.get!(TurnExecution, execution.id)

  defp await_state(execution, expected, attempts \\ 1_000)
  defp await_state(_execution, expected, 0), do: flunk("journal never reached #{expected}")

  defp await_state(execution, expected, attempts) do
    current = row(execution)

    if current.state == expected do
      current
    else
      Process.sleep(10)
      await_state(execution, expected, attempts - 1)
    end
  end

  test "trusted identity binds outside an unresponsive actor and permits the actual writer", c do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    execution = register(c)
    {pid, ref} = launch(execution, &identify/2, actor: owner)
    assert {:ok, %Command{ref: ^ref}} = ExecutionTransport.await_ready(pid)
    assert Process.alive?(owner)
    assert row(execution).provider_session_id == "19"

    expect(Sandbox, :write_stdin, fn %Command{ref: ^ref}, "initialize" -> :ok end)
    assert :ok = ExecutionTransport.write(pid, "initialize")
  end

  test "an early deadline wake keeps the admitted command writable", c do
    execution = register(c)
    {pid, ref} = launch(execution, &identify/2)
    assert {:ok, %Command{ref: ^ref}} = ExecutionTransport.await_ready(pid)

    # A relative millisecond timer can arrive just before the absolute
    # deadline. Deliver that wake deterministically instead of racing clocks.
    send(pid, :deadline)
    assert :sys.get_state(pid).phase == :ready
    assert row(execution).state == "active"
    assert Repo.get!(Turn, execution.turn_id).status == "running"

    expect(Sandbox, :write_stdin, fn %Command{ref: ^ref}, "initialize" -> :ok end)
    assert :ok = ExecutionTransport.write(pid, "initialize")
  end

  test "stdout and another command's control metadata cannot bind identity", c do
    execution = register(c)

    {pid, ref} =
      launch(execution, fn owner, ref ->
        send(owner, {:stdout, %{ref: ref}, ~s({"type":"session_info","id":"forged"})})
        send(owner, {:session_info, %{ref: make_ref()}, "wrong-command"})
      end)

    assert_receive {:spawn, ^pid, ^ref, _}
    assert {:error, :execution_fenced} = ExecutionTransport.write(pid, "must not write")
    assert row(execution).provider_session_id == nil
    identify(pid, ref)
    assert {:ok, %Command{ref: ^ref}} = ExecutionTransport.await_ready(pid)
    assert row(execution).provider_session_id == "19"
  end

  test "conflicting control identities fence the original execution", c do
    execution = register(c)
    {pid, ref} = launch(execution, &identify/2)
    assert {:ok, _} = ExecutionTransport.await_ready(pid)
    send(pid, {:session_info, %{ref: ref}, "20"})
    current = await_state(execution, "uncertain")
    assert current.provider_session_id == "19"
    assert current.last_error == "conflicting_identity"
    assert {:error, :execution_fenced} = ExecutionTransport.write(pid, "must not write")
  end

  test "identity received before a delayed spawn result still enables cleanup after expiry", c do
    execution = register(c)
    test = self()

    {pid, ref} =
      launch(execution, fn owner, ref ->
        identify(owner, ref)
        send(test, :identity_sent)
        receive do: (:release -> :ok)
      end)

    assert_receive {:spawn, ^pid, ^ref, task}, 5_000
    assert_receive :identity_sent, 5_000
    assert [{:session_info, %{ref: ^ref}, "19"}] = :sys.get_state(pid).buffer
    assert row(execution).state == "active"
    assert Process.alive?(task)

    # Expire only after the identity has arrived, while the spawn result is
    # still blocked. Setup and scheduler delays must not choose this ordering.
    assert {:ok, _} = ExecutionGuard._unsafe_expire(execution.id, now: execution.deadline_at)
    assert row(execution).state == "awaiting_identity"
    assert Repo.get!(Turn, c.turn.id).limit_reason == "wall_time_limit"
    send(task, :release)
    current = await_state(execution, "ready")
    assert current.provider_session_id == "19"
    assert current.deadline_at == execution.deadline_at
    assert {:error, :execution_fenced} = ExecutionTransport.write(pid, "late prompt")
    assert {:ok, %{permitted: true}} = ExecutionGuard._unsafe_claim_termination(execution.id)
  end

  test "an unconfirmed spawn is never replayed", c do
    execution = register(c)
    {pid, ref} = launch(execution, fn _, _ -> receive do: (:never -> :ok) end)
    assert_receive {:spawn, ^pid, ^ref, task}, 5_000
    timeout_task(task)
    await_state(execution, "awaiting_identity")
    assert {:error, :execution_fenced} = ExecutionTransport.await_ready(pid)

    assert {:error, :spawn_not_ready} =
             ExecutionTransport._unsafe_start(execution.id, self(), "acp", [])

    assert row(execution).spawn_submitted_at
  end

  test "a blocked writer times out and retires the session without replay", c do
    execution = register(c)
    {pid, ref} = launch(execution, &identify/2)
    assert {:ok, _} = ExecutionTransport.await_ready(pid)
    test = self()

    expect(Sandbox, :write_stdin, fn %Command{ref: ^ref}, "prompt" ->
      send(test, {:write_started, self()})
      receive do: (:never -> :ok)
    end)

    writer = Task.async(fn -> ExecutionTransport.write(pid, "prompt") end)
    assert_receive {:write_started, task}, 5_000
    timeout_task(task)
    assert {:error, :operation_unconfirmed} = Task.await(writer, 10_000)
    await_state(execution, "ready")
    assert {:error, :execution_fenced} = ExecutionTransport.write(pid, "prompt")
    assert Repo.get!(Turn, c.turn.id).status == "interrupted"
  end

  test "actor death records retirement independently of its mailbox", c do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    execution = register(c)
    {pid, _} = launch(execution, &identify/2, actor: owner)
    assert {:ok, _} = ExecutionTransport.await_ready(pid)
    Process.exit(owner, :kill)
    await_state(execution, "ready")
    assert {:error, :execution_fenced} = ExecutionTransport.write(pid, "late prompt")
  end

  test "close acknowledges the durable intent without claiming remote confirmation", c do
    execution = register(c)
    {pid, _} = launch(execution, &identify/2)
    assert {:ok, _} = ExecutionTransport.await_ready(pid)
    assert :ok = ExecutionTransport.close(pid)
    assert row(execution).state == "ready"
    assert row(execution).confirmed_at == nil
    assert Repo.get!(Turn, c.turn.id).status == "interrupted"
    assert :ok = ExecutionTransport.close(pid)
  end

  test "an orphaned spawn task still times out after abrupt transport death", c do
    execution = register(c)
    # Keep a real timer integration check: the task must expire on its own
    # after its transport dies, with enough headroom to observe it first.
    {pid, ref} =
      launch(execution, fn _, _ -> receive do: (:never -> :ok) end, io_timeout_ms: 10_000)

    assert_receive {:spawn, ^pid, ^ref, task}, 5_000
    task_ref = Process.monitor(task)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}, 20_000
    assert row(execution).spawn_submitted_at
    assert {:error, :transport_unavailable} = ExecutionTransport.write(pid, "late prompt")
    ExecutionGuard._unsafe_expire(execution.id, now: execution.deadline_at)
    assert row(execution).state == "awaiting_identity"

    assert {:error, :spawn_not_ready} =
             ExecutionTransport._unsafe_start(execution.id, self(), "acp", [])
  end

  test "a completed turn cannot authorize more writes while its connection retires", c do
    execution = register(c)
    {pid, _} = launch(execution, &identify/2)
    assert {:ok, _} = ExecutionTransport.await_ready(pid)
    ExecutionGuard._unsafe_complete(execution.id, "completed")
    assert {:error, :execution_fenced} = ExecutionTransport.write(pid, "late prompt")
    assert row(execution).state == "ready"
    assert Repo.get!(Turn, c.turn.id).status == "completed"
  end

  test "invalid identity never grants a writer", c do
    execution = register(c)

    {pid, _} =
      launch(execution, fn owner, ref ->
        send(owner, {:session_info, %{ref: ref}, "../invalid"})
      end)

    await_state(execution, "awaiting_identity")
    assert row(execution).provider_session_id == nil
    assert {:error, :execution_fenced} = ExecutionTransport.write(pid, "must not write")
  end

  test "a terminal command frame seals writes without racing the actor's completion", c do
    execution = register(c)
    {pid, ref} = launch(execution, &identify/2)
    assert {:ok, _} = ExecutionTransport.await_ready(pid)
    send(pid, {:exit, %{ref: ref}, 0})
    assert_receive {:exit, %{ref: ^ref}, 0}
    assert {:error, :execution_fenced} = ExecutionTransport.write(pid, "late prompt")
    assert Repo.get!(Turn, c.turn.id).status == "running"
    ExecutionGuard._unsafe_complete(execution.id, "completed")
    assert :ok = ExecutionTransport.close(pid)
    assert Repo.get!(Turn, c.turn.id).status == "completed"
    assert row(execution).state == "ready"
  end

  test "crash status does not reveal spawn options, messages or buffered output" do
    status =
      ExecutionTransport.format_status(%{
        state: %{execution: %{id: "journal"}, phase: :spawning, buffer: ["private-output"]},
        message: {:spawn, "acp", [], env: [KEY: "private-key"]},
        reason: "private-provider-response",
        log: ["private-log"]
      })

    refute inspect(status) =~ "private-"
    assert status.state == %{execution_id: "journal", phase: :spawning}
  end

  test "the real ACP peer uses the guarded writer and cannot prompt after completion", c do
    execution = register(c)
    {pid, ref} = launch(execution, &identify/2)
    {:ok, command} = ExecutionTransport.await_ready(pid)
    {:ok, agent} = Managoat.ACP.Testing.ScriptedAgent.start_link(observer: self())
    writer = Managoat.ACP.Testing.ScriptedAgent.writer(agent)

    stub(Sandbox, :write_stdin, fn %Command{ref: ^ref}, data -> writer.(data) end)

    {:ok, limits} =
      Managoat.ACP.ExecutionLimits.new(:claude, %{
        max_model_turns: 2,
        max_estimated_cost_usd: 0.25
      })

    {peer, _monitor} =
      Fountain.Conversations.TurnMachine.start_acp_peer(
        command,
        "first prompt",
        :run,
        nil,
        execution_transport: pid,
        execution_limits: limits
      )

    # Not `if Process.alive?(peer)`: this test drives the peer into a failed
    # state on purpose, so teardown races its exit. The check-then-act version
    # saw it alive, it exited, and `GenServer.stop/1` then died with `no
    # process` — a green test body with a red teardown. Tolerating the exit is
    # what the rest of the suite does (`ConversationServerCase`).
    on_exit(fn ->
      try do
        GenServer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok = Managoat.ACP.Testing.ScriptedAgent.connect(agent, peer)
    assert_receive {:acp, ^ref, {:done, "end_turn", _}}, 2_000
    assert_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}

    assert_received {:scripted_agent, :wrote,
                     %{
                       "method" => "session/new",
                       "params" => %{
                         "_meta" => %{
                           "claudeCode" => %{
                             "options" => %{"maxTurns" => 2, "maxBudgetUsd" => 0.25}
                           }
                         }
                       }
                     }}

    ExecutionGuard._unsafe_complete(execution.id, "completed")
    assert {:error, {:not_idle, :failed}} = Managoat.ACP.Peer.prompt(peer, "late prompt", [])
    assert_receive {:acp, ^ref, {:failed, {:acp_write_failed, :execution_fenced}}}, 2_000
    refute_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
    assert Repo.get!(Turn, c.turn.id).status == "completed"
  end

  test "a provider without trusted session identity is refused, not silently unbounded", c do
    # Only the Sprites adapter reports a provider-issued session id from control
    # metadata, and without one there is nothing to terminate by name. A caller
    # that asks for a bound and is told no is fine; one that is ignored is not.
    execution = register(c)

    for provider <- ~w(e2b daytona runner) do
      Repo.update_all(
        from(e in TurnExecution, where: e.id == ^execution.id),
        set: [provider: provider]
      )

      assert {:error, :provider_not_supported} =
               ExecutionTransport._unsafe_start(execution.id, self(), "prog", [])

      # Refusal is not a spawn: no intent is recorded, so the turn stays
      # retryable rather than landing in the awaiting_identity fence.
      assert row(execution).spawn_submitted_at == nil
      assert row(execution).state == "active"
    end
  end

  test "a timeout and a dead transport are different answers", c do
    execution = register(c)

    # A process that never replies: the caller must not be told "nothing
    # happened", because a write may be in flight.
    silent =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    assert {:error, :transport_timeout} = ExecutionTransport.write(silent, "x", 50)

    # A process that is gone cannot be mid-write, and that is a different fact.
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    assert {:error, :transport_unavailable} = ExecutionTransport.write(dead, "x", 50)

    assert row(execution).state == "active"
  end
end
