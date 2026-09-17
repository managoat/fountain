defmodule Fountain.Conversations.ConversationServerLifetimeTest do
  @moduledoc """
  A live ConversationServer reclaiming its own sandbox.

  The bound is checked on a one-minute timer. Most tests send
  `:lifecycle_check` directly to exercise the check itself; the "timer is
  actually wired" test shrinks the interval and waits for a real tick, so
  dropping `schedule_lifecycle_check()` from `init/1` fails a test instead
  of silently disabling reclamation (#337).
  """

  use Fountain.ConversationServerCase

  import Fountain.ConversationServerCase.ACP

  alias Fountain.Conversations.Lifecycle

  defp with_bounds(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  # These start from a `ready` sandbox, which routes the server down the
  # reattach path rather than a fresh provision. The shared harness only covers
  # provisioning, so the two reattach-specific calls are stubbed here.
  defp stub_reattach do
    # stub_happy_sprite/0 already stubs the adapter's get/1 probe, which is
    # all the reattach path needs beyond the shared harness.
    stub_happy_sprite()
  end

  defp aged_conversation(minutes, sandbox_attrs \\ [], agent_attrs \\ []) do
    user = insert_verified_user()
    agent = insert_agent([user_id: user.id] ++ agent_attrs)
    sandbox = insert_sandbox([user_id: user.id, status: "ready"] ++ sandbox_attrs)

    ts = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)

    Fountain.Repo.update_all(
      from(s in Fountain.Conversations.Sandbox, where: s.id == ^sandbox.id),
      set: [inserted_at: ts]
    )

    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    {conv, Fountain.Repo.reload(sandbox)}
  end

  describe "idle timeout" do
    test "an idle server suspends its sandbox — sprite kept — and stops" do
      {conv, sandbox} = aged_conversation(180)
      stub_reattach()

      # The whole point of decisions/0017: the sprite's disk holds the agent's
      # memory, and the idle bound must not destroy it.
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        # last_activity_at is set at init, so age it to look abandoned.
        :sys.replace_state(pid, fn state ->
          %{state | last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)}
        end)

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(ref)
      end)

      reloaded = Fountain.Repo.reload(sandbox)
      assert reloaded.status == "suspended"
      refute reloaded.terminated_at
    end

    test "the timer is actually wired: suspension fires with no manual tick" do
      {conv, sandbox} = aged_conversation(180)
      stub_reattach()

      Application.put_env(:fountain, :lifecycle_check_ms, 50)
      on_exit(fn -> Application.delete_env(:fountain, :lifecycle_check_ms) end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        :sys.replace_state(pid, fn state ->
          %{state | last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)}
        end)

        # No send(pid, :lifecycle_check) — the scheduled tick must do it.
        assert :normal = assert_stopped(ref, 5_000)
      end)

      assert Fountain.Repo.reload(sandbox).status == "suspended"
    end

    test "the conversation stays resumable" do
      # The whole design rests on this. assert_resumable/1 refuses terminated,
      # so if reclaiming marked the conversation the user would lose access to
      # their own history permanently — a cost control turned into data loss.
      {conv, _sandbox} = aged_conversation(180)
      stub_reattach()

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        :sys.replace_state(pid, fn state ->
          %{state | last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)}
        end)

        send(pid, :lifecycle_check)
        assert_stopped(ref)
      end)

      assert Fountain.Repo.reload(conv).status == "idle"
    end

    test "a request that outlived its turn does not hold the sandbox open" do
      # The whole point of #1635. A request held inside a running turn defers
      # idle reclaim, which is why its ceiling has to sit under the idle
      # bound; a detached one holds nothing, so the machine parks with the
      # card still up and the answer wakes it.
      {conv, sandbox} = aged_conversation(180)
      stub_reattach()
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      turn =
        insert_turn(conv, %{
          status: "completed",
          waiting: true,
          pending_permission: %{
            "request_id" => "7.abc",
            "tool" => "Bash",
            "options" => [%{"optionId" => "yes", "kind" => "allow_once"}]
          },
          permission_deadline:
            DateTime.utc_now()
            |> DateTime.add(2 * 24 * 3600, :second)
            |> DateTime.truncate(:second)
        })

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        :sys.replace_state(pid, fn state ->
          %{state | last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)}
        end)

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(ref)
      end)

      assert Fountain.Repo.reload(sandbox).status == "suspended"

      # And the request survived the park, disk and row alike.
      reloaded = Fountain.Repo.reload(turn)
      assert reloaded.waiting
      assert reloaded.pending_permission["request_id"] == "7.abc"
      assert [%{request_id: "7.abc"}] = Conversations._unsafe_list_pending_requests(conv.id)
    end

    test "a recently active server is left running" do
      {conv, sandbox} = aged_conversation(180)
      stub_reattach()

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 999], fn ->
        {pid, _ref, :alive} = start_server(conv)

        send(pid, :lifecycle_check)
        # A synchronous call after the cast proves it processed the message and
        # is still alive.
        assert is_map(:sys.get_state(pid))

        GenServer.stop(pid)
      end)

      assert Fountain.Repo.reload(sandbox).status == "ready"
    end

    test "bounds disabled means the server never reclaims" do
      {conv, sandbox} = aged_conversation(60 * 24 * 83)
      stub_reattach()

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 0], fn ->
        {pid, _ref, :alive} = start_server(conv)

        :sys.replace_state(pid, fn state ->
          %{state | last_activity_at: DateTime.add(DateTime.utc_now(), -99_999_999, :second)}
        end)

        send(pid, :lifecycle_check)
        assert is_map(:sys.get_state(pid))

        GenServer.stop(pid)
      end)

      assert Fountain.Repo.reload(sandbox).status == "ready"
    end
  end

  describe "idle timeout on a provider that cannot park" do
    test "idle destroys instead of suspending, and says so honestly" do
      {conv, sandbox} = aged_conversation(180)
      stub_reattach()
      test = self()

      # A provider without the :suspend capability cannot park with the disk
      # preserved; the idle bound degrades to the destroy arm.
      stub(Managoat.Sandbox.Sprites, :capabilities, fn ->
        MapSet.new([:network_policy, :attach])
      end)

      stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> send(test, :destroyed) && :ok end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        :sys.replace_state(pid, fn state ->
          %{state | last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)}
        end)

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(ref)
      end)

      assert_received :destroyed
      assert Fountain.Repo.reload(sandbox).status == "terminated"
      assert Fountain.Repo.reload(conv).status in ["idle", "pending"]
    end

    test "a failed suspend call degrades to destroy — an unparked sandbox keeps billing" do
      {conv, sandbox} = aged_conversation(180)
      stub_reattach()
      test = self()

      stub(Managoat.Sandbox.Sprites, :suspend, fn _handle ->
        {:error, {:unavailable, :timeout}}
      end)

      stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> send(test, :destroyed) && :ok end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        :sys.replace_state(pid, fn state ->
          %{state | last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)}
        end)

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(ref)
      end)

      assert_received :destroyed
      assert Fountain.Repo.reload(sandbox).status == "terminated"
    end
  end

  describe "max lifetime" do
    test "an old sandbox is destroyed even with recent activity" do
      # The regression anchor for the idle/max split: the ceiling exists for
      # runaway compute and must KEEP destroying the sprite, unlike the idle
      # bound above.
      {conv, sandbox} = aged_conversation(60 * 48)
      stub_reattach()

      test = self()
      stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> send(test, :destroyed) && :ok end)

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(ref)
      end)

      assert_received :destroyed
      assert Fountain.Repo.reload(sandbox).status == "terminated"
    end

    test "the ceiling is dated from the sandbox row, not from server start" do
      # Otherwise every restart, reattach and deploy would reset the ceiling and
      # a long-lived sandbox would never reach it.
      {conv, sandbox} = aged_conversation(60 * 48)
      stub_reattach()

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        assert %{sandbox_started_at: started} = :sys.get_state(pid)
        assert DateTime.compare(started, sandbox.inserted_at) == :eq

        send(pid, :lifecycle_check)
        assert_stopped(ref)
      end)
    end

    test "a home at the ceiling is parked even with this server's own turn in flight" do
      # The case the ceiling exists for, and the one it is hardest to reach:
      # `Lifecycle.check/4`'s `busy?` suppresses the *idle* verdict only, so
      # `{:expired, :max_lifetime}` fires while this server is mid-prompt.
      # A home parks rather than being destroyed (ADR 0023 step 5), and the
      # turn in flight is cut — `explain(:max_lifetime, :suspend)` says so in
      # as many words.
      #
      # ADR 0058 stage 6b put a running-turn check under the machine's lease,
      # and the first draft of it was machine-wide: this park refused itself,
      # the server stayed alive with its connection already dropped, its turn
      # stayed `running` with no adapter left to end it, and the ceiling
      # re-fired every minute against a machine that went on billing.
      {conv, sandbox} = aged_conversation(60 * 48, [mode: "persistent"], runtime: "claude")
      # Order matters: `stub_happy_sprite/0` stubs `spawn/4` permissively, so
      # the ACP transport has to be wired after it or the handshake never
      # reaches this process.
      stub_reattach()
      ref = stub_acp_transport()
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        {pid, mon, :alive} = start_server(conv, initial_prompt: "first")
        _prompt_id = drive_to_prompt(pid, ref)

        assert [%{status: "running"}] = Fountain.Conversations._unsafe_list_turns(conv.id)

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(mon)
      end)

      assert Fountain.Repo.reload(sandbox).status == "suspended",
             "the ceiling could not park the machine, so it goes on billing with " <>
               "nothing left to stop it"

      assert [%{status: "interrupted", orphaned_at: at}] =
               Fountain.Conversations._unsafe_list_turns(conv.id)

      assert at, "the cut turn was left running with no adapter and no server to end it"
      assert Fountain.Repo.reload(conv).status == "idle"
    end

    test "a co-tenant's running turn still stops the ceiling from parking the machine" do
      # The other half of the same rule: this server's *own* turn is what the
      # ceiling is cutting, and somebody else's is not. A machine another
      # conversation is working on is left alone and asked again next tick.
      {conv, sandbox} = aged_conversation(60 * 48, mode: "persistent")
      stub_reattach()
      reject(&Managoat.Sandbox.Sprites.destroy/1)
      reject(&Managoat.Sandbox.Sprites.suspend/1)

      other =
        insert_conversation(user_id: conv.user_id, sandbox_id: sandbox.id, status: "running")

      insert_turn(other, status: "running", started_at: DateTime.utc_now())

      # And a server driving it. Since stage 6b a `running` turn row whose
      # conversation has no live server is a leftover rather than occupancy —
      # the permission-parked turn nothing ever clears — so without this the
      # machine would (rightly) park and this test would be about the wrong
      # rule.
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, other.id, nil)
           receive do: (:never -> :ok)
         end},
        id: {:cotenant, other.id}
      )

      assert {:ok, _} = Conversations.ConversationServer.await_registered(other.id, 2_000)

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        {pid, _mon, :alive} = start_server(conv)

        send(pid, :lifecycle_check)
        assert is_map(:sys.get_state(pid)), "the server gave up on a machine still in use"
        GenServer.stop(pid)
      end)

      assert Fountain.Repo.reload(sandbox).status == "ready"
    end

    for {label, answer} <- [
          {"a machine it cannot reach right now", {:error, :sandbox_unavailable}},
          {"an abandoned park it recovered instead", {:error, :recovered}}
        ] do
      test "the server keeps the machine when the park answers with #{label}" do
        # `reclaim_refused/2`'s other two inputs. A park that was refused for a
        # reason the server cannot act on leaves the machine exactly as it was
        # and asks again on the next tick — the same thing a refused destroy
        # has always done. What must not happen is the server stopping, which
        # would leave a live machine with nothing watching it until the hourly
        # sweep. Driven at `park_sandbox/2`'s own seam: `Machines.Park` decides
        # these words and `park_test.exs` pins that it does.
        {conv, sandbox} = aged_conversation(60 * 48, mode: "persistent")
        stub_reattach()
        reject(&Managoat.Sandbox.Sprites.destroy/1)
        stub(Lifecycle, :park, fn _conv_id, _sandbox_id, _handle, _reason -> unquote(answer) end)

        with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
          {pid, _mon, :alive} = start_server(conv)

          send(pid, :lifecycle_check)
          assert is_map(:sys.get_state(pid)), "the server gave up on a machine it still holds"
          GenServer.stop(pid)
        end)

        assert Fountain.Repo.reload(sandbox).status == "ready"
      end
    end

    test "a wake from suspended restarts the ceiling clock" do
      # A conversation parked for days must not be destroyed the moment it is
      # woken: the ceiling measures a continuous run, so it is dated from
      # last_resumed_at when the sandbox has been through a suspend/wake.
      {conv, sandbox} = aged_conversation(60 * 48)
      stub_reattach()
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      resumed_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        Fountain.Conversations.update_sandbox(Fountain.Repo.reload(sandbox), %{
          last_resumed_at: resumed_at
        })

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        {pid, _ref, :alive} = start_server(conv)

        assert %{sandbox_started_at: started} = :sys.get_state(pid)
        assert DateTime.compare(started, resumed_at) == :eq

        send(pid, :lifecycle_check)
        # Two-day-old row, minute-old resume: the server must stay up.
        assert is_map(:sys.get_state(pid))
        GenServer.stop(pid)
      end)

      assert Fountain.Repo.reload(sandbox).status == "ready"
    end
  end

  describe "before a sprite exists" do
    test "nothing is reclaimed while sandbox_started_at is unset" do
      # sandbox_started_at is nil until the sprite is up. Reclaiming in that
      # window would fight the provisioner; the reaper's stuck-row pass owns
      # it. The harness cannot hold a server mid-provision (handle_continue
      # blocks the mailbox until it settles), so: settle the server, then
      # clear sandbox_started_at to reproduce the in-flight state and age
      # last_activity_at past the (tight) bounds. Only the nil guard in
      # :lifecycle_check keeps this server alive.
      {conv, sandbox} = aged_conversation(60 * 24)
      stub_reattach()

      with_bounds([sandbox_idle_timeout_minutes: 1, sandbox_max_lifetime_hours: 1], fn ->
        {pid, _ref, :alive} = start_server(conv)

        :sys.replace_state(pid, fn state ->
          %{
            state
            | sandbox_started_at: nil,
              last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)
          }
        end)

        send(pid, :lifecycle_check)
        # Alive, untouched, and started_at still unset after the tick.
        assert %{sandbox_started_at: nil} = :sys.get_state(pid)
        GenServer.stop(pid)
      end)

      assert Fountain.Repo.reload(sandbox).status == "ready"
    end
  end

  describe "the reclaim message" do
    test "explains itself in terms the user can act on" do
      with_bounds([sandbox_idle_timeout_minutes: 90, sandbox_max_lifetime_hours: 6], fn ->
        assert Lifecycle.explain(:idle) =~ "90 minutes idle"
        assert Lifecycle.explain(:max_lifetime) =~ "6 hour"
      end)
    end
  end
end
