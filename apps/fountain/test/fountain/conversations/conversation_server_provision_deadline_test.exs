defmodule Fountain.Conversations.ConversationServerProvisionDeadlineTest do
  # #329: a ConversationServer stuck inside provisioning was invisible to
  # every reclamation mechanism — the reaper exempts rows whose server is
  # alive, and the server's own timers queue behind the stuck
  # handle_continue. The provision watchdog is an external process that
  # kills the server at an absolute deadline and applies the same
  # failed/failed transitions as the normal provision-failure path.
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.ProvisionWatchdog

  setup do
    test_pid = self()

    # Keep the production deadline. Capture the real watchdog so each test can
    # deliver its timer message after the state under test has been reached.
    Mimic.stub(ProvisionWatchdog, :start, fn conv_id, sandbox_id ->
      pid = Mimic.call_original(ProvisionWatchdog, :start, [conv_id, sandbox_id])
      send(test_pid, {:watchdog_started, self(), pid})
      pid
    end)

    :ok
  end

  defp stall_provision do
    test_pid = self()

    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
      send(test_pid, {:provision_stalled, self()})
      Process.sleep(:infinity)
    end)
  end

  defp start_provision_server(conv) do
    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: Managoat.Runtimes.Testing.FakeRuntime
    ]

    # A failed readiness assertion must not leave a stuck server and its
    # watchdog behind after the SQL Sandbox owner exits. Stay outside Horde
    # so the tests control restarts explicitly.
    start_supervised!(%{
      id: make_ref(),
      start: {GenServer, :start_link, [ConversationServer, args]},
      restart: :temporary,
      shutdown: :brutal_kill
    })
  end

  # The watchdog fires **after** the provision's lease has lapsed, and that is
  # the contract rather than an artefact of the test (ADR 0058 stage 7b): its
  # timer is `deadline_ms/0` plus a grace long enough for the renewals to have
  # stopped and the last one to have run out. Driving the timer by hand skips
  # the wall-clock wait, so the lease has to be expired by hand too, or this
  # would be testing the one situation the grace exists to prevent — a watchdog
  # arriving while an owner legitimately holds the machine.
  #
  # `ProvisionWatchdog.retire_wait_ms/0` covers it either way; expiring the
  # lease is what keeps these tests to seconds rather than minutes.
  defp expire_watchdog(server) do
    watchdog = arm_watchdog(server)
    ref = Process.monitor(watchdog)
    send(watchdog, :provision_deadline)
    assert_receive {:DOWN, ^ref, :process, ^watchdog, :normal}, 10_000
  end

  # The same, for a watchdog that is *not* expected to exit — a refused retire
  # re-arms and comes back (round 1), so the caller drives the attempts itself.
  defp arm_watchdog(server) do
    assert_receive {:watchdog_started, ^server, watchdog}, 5_000
    lapse_lease()
    watchdog
  end

  defp provision_stages(conv_id) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "stage" and &1.stage == "provision"))
    |> Enum.map(& &1.state)
  end

  # Past, for every machine in this test's tenant — the suite runs one
  # conversation at a time and the renewer's next tick is a third of a minute
  # away, so this stands for as long as the watchdog needs.
  defp lapse_lease do
    Fountain.Repo.update_all(Fountain.Conversations.Sandbox,
      set: [lease_until: DateTime.add(DateTime.utc_now(), -60, :second)]
    )
  end

  test "the configured timer expires a pending provision" do
    # Both knobs, because the watchdog's timer is the provision's deadline plus
    # the grace that lets the machine's lease lapse (ADR 0058 stage 7b). Zero
    # for both is what makes this the one test that watches the real timer
    # instead of delivering its message by hand — and the row it fires on has
    # no owner and no lease, so there is nothing for the grace to wait out.
    for key <- [:provision_deadline_ms, :provision_lapse_grace_ms] do
      previous = Application.fetch_env(:fountain, key)
      Application.put_env(:fountain, key, 0)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:fountain, key, value)
          :error -> Application.delete_env(:fountain, key)
        end
      end)
    end

    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)

    # The pending rows already exist, so an immediate timer has no provisioning
    # work to race. The other tests exercise the real server's transitions.
    pid =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :start_watchdog -> ProvisionWatchdog.start(conv.id, conv.sandbox_id)
           end

           Process.sleep(:infinity)
         end}
      )

    ref = Process.monitor(pid)
    send(pid, :start_watchdog)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
    assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
  end

  test "a hung provision is killed at the deadline and its rows are failed" do
    stub_happy_sprite()

    # Stall provisioning indefinitely — the shape of a step that hangs
    # without raising (e.g. a stream that stops yielding chunks).
    stall_provision()

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    pid = start_provision_server(conv)
    ref = Process.monitor(pid)
    assert_receive {:provision_stalled, ^pid}, 5_000
    expire_watchdog(pid)

    # The watchdog must kill the stuck server…
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    # …and then free the quota slot by failing the rows.
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"

    assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
  end

  test "the rows are terminal before the server is terminated (#394)" do
    # Pre-#394 the watchdog killed first and wrote the rows after. The server
    # is restart: :transient, so under Horde the kill triggered a restart that
    # re-read a still-pending row and provisioned a second billable sprite.
    # This pins the new contract: termination goes through the supervisor,
    # and by the time it happens the sandbox row is already failed — which is
    # what makes any restart stop at the terminal-status guard.
    stub_happy_sprite()

    stall_provision()

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    test_pid = self()
    sandbox_id = conv.sandbox_id

    Mimic.stub(Horde.DynamicSupervisor, :terminate_child, fn _sup, pid ->
      status = Conversations._unsafe_get_sandbox!(sandbox_id).status
      send(test_pid, {:status_at_termination, status})
      Process.exit(pid, :kill)
      :ok
    end)

    pid = start_provision_server(conv)
    ref = Process.monitor(pid)
    assert_receive {:provision_stalled, ^pid}, 5_000
    expire_watchdog(pid)

    assert_receive {:status_at_termination, "failed"}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end

  test "a server restarted after the deadline provisions no second sprite (#394)" do
    handle = stub_happy_sprite()
    test_pid = self()

    # Count every sprite creation across all processes (global mode).
    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts ->
      send(test_pid, :sprite_created)
      {:ok, handle}
    end)

    stall_provision()

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    pid = start_provision_server(conv)
    ref = Process.monitor(pid)
    assert_receive {:provision_stalled, ^pid}, 5_000
    expire_watchdog(pid)

    assert_receive :sprite_created, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    # What Horde's transient restart does after the watchdog fires: start a
    # fresh server on the same conversation, immediately. It must read the
    # terminal row and stop — never create a second sprite.
    pid2 = start_provision_server(conv)
    ref2 = Process.monitor(pid2)

    assert_receive {:DOWN, ^ref2, :process, ^pid2, :normal}, 5_000
    refute_received :sprite_created
  end

  test "a machine it cannot retire is retried, and only then is the server stopped" do
    # The #394 ordering as a *condition* rather than a sequence (ADR 0058 stage
    # 7b): the rows go terminal before the kill so a restart stops at the
    # terminal-status guard, which means a retire the owner refuses must not be
    # followed by a kill.
    #
    # **What that cannot be is "do nothing, for ever"** (round 1, protocol and
    # surfaces reviews, both probed). The first draft left the row to
    # `SandboxReaper.release_stuck_sandboxes/0`, which rejects rows whose server
    # is alive — and the refusal arm is the one that deliberately keeps it
    # alive. So the row sat `starting`, holding a quota slot, until the next
    # deploy: exactly what #329 exists to prevent, and unreachable on `main`.
    #
    # So the refusal is retried, and after `max_retire_attempts/0` the ceiling
    # falls back to `main`'s — the server is stopped although the row is live,
    # through the supervisor, which removes the child rather than restarting it.
    for key <- [:provision_retire_retry_ms] do
      previous = Application.fetch_env(:fountain, key)
      Application.put_env(:fountain, key, 0)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:fountain, key, value)
          :error -> Application.delete_env(:fountain, key)
        end
      end)
    end

    stub_happy_sprite()
    stall_provision()

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    test_pid = self()

    Mimic.stub(Fountain.Machines.Machine, :fail_provision, fn _id, _opts ->
      send(test_pid, :retire_refused)
      {:error, :sandbox_unavailable}
    end)

    pid = start_provision_server(conv)
    ref = Process.monitor(pid)
    assert_receive {:provision_stalled, ^pid}, 5_000

    watchdog = arm_watchdog(pid)
    watchdog_ref = Process.monitor(watchdog)
    send(watchdog, :provision_deadline)

    # Every attempt asks, and the server survives all but the last.
    for _ <- 1..ProvisionWatchdog.max_retire_attempts() do
      assert_receive :retire_refused, 5_000
    end

    # …and then the fallback: the server is stopped so the reaper can see the
    # row at all, and the watchdog is done.
    assert_receive {:DOWN, ^watchdog_ref, :process, ^watchdog, :normal}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

    # The row is untouched by the watchdog — that is the half of #394 that does
    # not change — and now has no live server, which is what
    # `release_stuck_sandboxes/0` needs.
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status in ["pending", "starting"]
    refute_received :retire_refused

    # And the conversation **is** failed on this arm: `{:error, _}` means this
    # owner could not reach the row at all, so nobody else is finishing this
    # conversation and `release_stuck_sandboxes/0` fails the sandbox row only.
    # Leaving it would strand a `pending` conversation with no server and
    # nothing that resolves it (round 2, protocol review).
    assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"

    # …and the client is told, because on this arm the conversation really is
    # over. `provision`/`failed` is terminal to a streaming client
    # (`cli/internal/acp/prompt.go` ends the turn on it), so it belongs with the
    # row write and nowhere else — see the sibling test.
    assert "failed" in provision_stages(conv.id)
  end

  test "a machine another owner holds leaves that owner's conversation alone" do
    # The other half of the same arm, and the reason it is not unconditional.
    # `{:ok, :claimed_elsewhere}` means a successor holds the machine and is
    # very likely building *this* conversation's — failing it would mark a live
    # conversation dead while its machine comes up, which is the one thing every
    # stand-down arm in this stage exists to prevent.
    for key <- [:provision_retire_retry_ms] do
      previous = Application.fetch_env(:fountain, key)
      Application.put_env(:fountain, key, 0)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:fountain, key, value)
          :error -> Application.delete_env(:fountain, key)
        end
      end)
    end

    stub_happy_sprite()
    stall_provision()

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    test_pid = self()

    Mimic.stub(Fountain.Machines.Machine, :fail_provision, fn _id, _opts ->
      send(test_pid, :retire_refused)
      {:ok, :claimed_elsewhere}
    end)

    pid = start_provision_server(conv)
    ref = Process.monitor(pid)
    assert_receive {:provision_stalled, ^pid}, 5_000

    watchdog = arm_watchdog(pid)
    watchdog_ref = Process.monitor(watchdog)
    send(watchdog, :provision_deadline)

    for _ <- 1..ProvisionWatchdog.max_retire_attempts() do
      assert_receive :retire_refused, 5_000
    end

    assert_receive {:DOWN, ^watchdog_ref, :process, ^watchdog, :normal}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

    # The orphan server is stopped either way — it is the thing keeping the
    # reaper from the row — but the conversation is the successor's.
    assert Conversations._unsafe_get_conversation!(conv.id).status != "failed"

    # **And nothing is announced on it** (round 3, surfaces review). The first
    # draft decided about the row and then published `provision/failed`
    # unconditionally, which is terminal to a streaming client: a CLI or an
    # editor watching this conversation aborted the prompt with "the sandbox
    # never started" while the successor's machine was coming up. Keeping the
    # conversation alive and telling its client it died is worse than either on
    # its own.
    refute "failed" in provision_stages(conv.id),
           "the loser announced a terminal provision on the successor's conversation"
  end

  test "a retire that succeeds on a later attempt kills the server and never retries again" do
    # The ordinary refusal — a lock held for the whole wait, a database fault —
    # clears, and the retry is what makes the ceiling land instead of the
    # fallback. Pinned separately because the fallback above would pass with the
    # retry doing nothing at all.
    for key <- [:provision_retire_retry_ms] do
      previous = Application.fetch_env(:fountain, key)
      Application.put_env(:fountain, key, 0)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:fountain, key, value)
          :error -> Application.delete_env(:fountain, key)
        end
      end)
    end

    stub_happy_sprite()
    stall_provision()

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    test_pid = self()
    attempts = :counters.new(1, [])

    Mimic.stub(Fountain.Machines.Machine, :fail_provision, fn id, opts ->
      :counters.add(attempts, 1, 1)
      send(test_pid, {:retire, :counters.get(attempts, 1)})

      if :counters.get(attempts, 1) == 1,
        do: {:error, :sandbox_unavailable},
        else: Mimic.call_original(Fountain.Machines.Machine, :fail_provision, [id, opts])
    end)

    pid = start_provision_server(conv)
    ref = Process.monitor(pid)
    assert_receive {:provision_stalled, ^pid}, 5_000

    watchdog = arm_watchdog(pid)
    watchdog_ref = Process.monitor(watchdog)
    send(watchdog, :provision_deadline)

    assert_receive {:retire, 1}, 5_000
    assert_receive {:retire, 2}, 5_000
    assert_receive {:DOWN, ^watchdog_ref, :process, ^watchdog, :normal}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    # The second attempt landed, so this is the ordinary ceiling: rows terminal.
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
    assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    refute_received {:retire, 3}
  end

  test "a provision that completes in time is left alone" do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    pid = start_provision_server(conv)
    # handle_continue runs before this call. The ExUnit timeout bounds a
    # genuinely stuck provision; successful setup has no short call deadline.
    :sys.get_state(pid, :infinity)

    # Provisioning has finished; now deliver the same
    # deadline message as the timer and wait until its row check has completed.
    expire_watchdog(pid)
    assert Process.alive?(pid)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"

    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end
end
