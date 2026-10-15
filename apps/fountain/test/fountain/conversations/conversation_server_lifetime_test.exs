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

  describe "a turn row nobody in this server is holding (#2529)" do
    # The in-memory `current_turn` is what suppresses the idle verdict. A
    # `running` row the server lost track of — a reattach that could not take
    # its turn back — must still hold the machine: an idle reclaim never ends a
    # turn in flight.
    defp lose_running_turn(pid, conv) do
      turn = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

      :sys.replace_state(pid, fn state ->
        %{
          state
          | current_turn: nil,
            last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)
        }
      end)

      turn
    end

    test "keeps a parkable machine" do
      {conv, sandbox} = aged_conversation(180)
      stub_reattach()
      reject(&Managoat.Sandbox.Sprites.suspend/1)
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, _ref, :alive} = start_server(conv)
        turn = lose_running_turn(pid, conv)

        send(pid, :lifecycle_check)
        assert is_map(:sys.get_state(pid))
        assert Fountain.Repo.reload(turn).status == "running"
        GenServer.stop(pid)
      end)

      assert Fountain.Repo.reload(sandbox).status == "ready"
    end

    test "keeps a machine its provider cannot park, which nothing else checked" do
      {conv, sandbox} = aged_conversation(180)
      stub_reattach()

      stub(Managoat.Sandbox.Sprites, :capabilities, fn ->
        MapSet.new([:network_policy, :attach])
      end)

      reject(&Managoat.Sandbox.Sprites.destroy/1)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, _ref, :alive} = start_server(conv)
        turn = lose_running_turn(pid, conv)

        send(pid, :lifecycle_check)
        assert is_map(:sys.get_state(pid))
        assert Fountain.Repo.reload(turn).status == "running"
        GenServer.stop(pid)
      end)

      assert Fountain.Repo.reload(sandbox).status == "ready"
    end
  end

  describe "max lifetime" do
    test "a turn in flight is ended on the turn stage, with the reason (#2529)" do
      {conv, sandbox} = aged_conversation(60 * 48)
      stub_reattach()

      test = self()
      stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> send(test, :destroyed) && :ok end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)

        turn = insert_turn(conv, status: "running", started_at: DateTime.utc_now())
        :sys.replace_state(pid, fn state -> %{state | current_turn: turn} end)

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(ref)

        assert Fountain.Repo.reload(turn).status == "interrupted"

        assert [ended] =
                 conv.id
                 |> Fountain.Conversations._unsafe_list_log_events()
                 |> Enum.filter(&(&1.kind == "stage" and &1.stage == "turn"))

        assert ended.state == "interrupted"
        assert ended.turn_id == turn.id

        assert %{"reason" => "sandbox_reclaimed", "detail" => "max_lifetime"} =
                 Jason.decode!(ended.data)
      end)

      assert_received :destroyed
      assert Fountain.Repo.reload(sandbox).status == "terminated"
    end

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

    test "a wake from suspended restarts the ceiling clock" do
      # A conversation parked for days must not be destroyed the moment it is
      # woken: the ceiling measures a continuous run, so it is dated from
      # last_resumed_at when the sandbox has been through a suspend/wake.
      {conv, sandbox} = aged_conversation(60 * 48)
      stub_reattach()
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      resumed_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        update_sandbox(Fountain.Repo.reload(sandbox), %{
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
