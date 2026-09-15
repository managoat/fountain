defmodule Fountain.Workers.SandboxReaperTest do
  @moduledoc """
  Reconciliation between the `sandboxes` table and sprites.dev.

  The risk here is asymmetric and points in one direction: failing to reap a
  sprite costs money and quota, while reaping the wrong one destroys someone's
  running work and cannot be undone. So most of these tests are about what the
  reaper refuses to touch.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Workers.SandboxReaper

  setup :set_mimic_global

  defp minutes_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 60, :second) |> DateTime.truncate(:second)

  # updated_at is managed by Ecto, so age has to be forced with a raw update.
  defp age_sandbox(sandbox, minutes) do
    ts = minutes_ago(minutes)
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [updated_at: ts])
    %{sandbox | updated_at: ts}
  end

  defp stub_sprites(names) do
    stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:ok, MapSet.new(names)} end)
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> :client end)
  end

  defp capture_destroys do
    test = self()

    stub(Sprites, :sprite, fn :client, name -> {:handle, name} end)

    stub(Sprites, :destroy, fn {:handle, name} ->
      send(test, {:destroyed, name})
      :ok
    end)
  end

  defp destroyed_names do
    receive do
      {:destroyed, name} -> [name | destroyed_names()]
    after
      0 -> []
    end
  end

  describe "stuck sandboxes" do
    test "a row stuck in pending past the grace period is released" do
      # This is the quota half: Quotas counts pending/starting toward the
      # concurrent cap, so a row left behind by a BEAM that died mid-provision
      # consumes a tenant's allowance forever, with no self-serve way out.
      sandbox = insert_sandbox(status: "pending") |> age_sandbox(120)

      capture_log(fn -> assert 1 = SandboxReaper.release_stuck_sandboxes() end)

      assert %{status: "failed", terminated_at: %DateTime{}} = Repo.reload(sandbox)
    end

    test "starting is released too" do
      sandbox = insert_sandbox(status: "starting") |> age_sandbox(120)

      capture_log(fn -> assert 1 = SandboxReaper.release_stuck_sandboxes() end)

      assert Repo.reload(sandbox).status == "failed"
    end

    test "a recent row is left alone" do
      # A slow provision is not a stuck one. Package installs get 300s per
      # command and a clone gets 600s, and they run in sequence.
      sandbox = insert_sandbox(status: "pending") |> age_sandbox(5)

      assert 0 = SandboxReaper.release_stuck_sandboxes()
      assert Repo.reload(sandbox).status == "pending"
    end

    test "a ready sandbox is never released, however old" do
      # An idle sandbox is a lifetime question (#167), not a stuck one. Marking
      # it failed here would kill live conversations.
      sandbox = insert_sandbox(status: "ready") |> age_sandbox(60 * 24 * 90)

      assert 0 = SandboxReaper.release_stuck_sandboxes()
      assert Repo.reload(sandbox).status == "ready"
    end

    test "a row with a live ConversationServer is left alone" do
      # Whatever the clock says, a running server means provisioning is still
      # in flight somewhere in the cluster.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending") |> age_sandbox(600)
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)

      stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
        if id == conv.id, do: self(), else: nil
      end)

      assert 0 = SandboxReaper.release_stuck_sandboxes()
      assert Repo.reload(sandbox).status == "pending"
    end
  end

  describe "abandoned ready sandboxes" do
    defp with_bounds(pairs, fun) do
      previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
      Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

      try do
        fun.()
      after
        Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
      end
    end

    defp age_rows(sandbox, conv, minutes) do
      ts = minutes_ago(minutes)

      # updated_at ages too: the sweep's grace window keys on it, and a row
      # this old that was genuinely abandoned has not been touched either.
      Repo.update_all(
        from(s in Sandbox, where: s.id == ^sandbox.id),
        set: [inserted_at: ts, updated_at: ts]
      )

      if conv do
        Repo.update_all(
          from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
          set: [inserted_at: ts]
        )
      end

      Repo.reload(sandbox)
    end

    test "past the ceiling with no server, a ready sandbox is expired" do
      # The 83-day production sandbox. Its ConversationServer is long gone, so
      # nothing was watching it. Both bounds are crossed at that age and the
      # ceiling wins: an unattended row this old only exists if the reaper
      # itself was down past the idle window that would have parked it, and
      # the ceiling is the backstop that still bounds it.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 24 * 83)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {0, 1} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      assert Repo.reload(sandbox).status == "terminated"

      # The conversation must survive — reclaiming is a cost control, not a
      # delete. assert_resumable/1 refuses terminated/failed/completed, so
      # marking it here would lock the user out of their own history forever.
      assert Repo.reload(conv).status == "idle"
      refute Repo.reload(conv).status in ~w(terminated failed completed)
    end

    test "past the idle bound but under the ceiling, a ready sandbox is parked" do
      # The common case after a crash or deploy gap: the server that would
      # have suspended it is gone. Parking is the reaper doing the server's
      # idle-suspend on its behalf — the sprite stays (decisions/0017).
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 5)

      capture_destroys()

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      reloaded = Repo.reload(sandbox)
      assert reloaded.status == "suspended"
      refute reloaded.terminated_at
      assert destroyed_names() == []
      assert Repo.reload(conv).status == "idle"
    end

    test "parking a persistent home checkpoints it first, where the provider can" do
      # The reaper is the park path for a home whose server is gone; the
      # checkpoint is the machine's last-quiet state (ADR 0023, #1073).
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready", mode: "persistent")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 5)

      capture_destroys()
      stub(Managoat.Sandbox, :supports?, fn :sprites, cap -> cap in [:suspend, :checkpoint] end)
      stub(Managoat.Sandbox, :create_checkpoint, fn _handle, _opts -> {:ok, "v2"} end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      reloaded = Repo.reload(sandbox)
      assert reloaded.status == "suspended"
      assert reloaded.provider_meta["checkpoint_id"] == "v2"
      assert destroyed_names() == []
    end

    test "an ephemeral sandbox parks without a checkpoint" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 5)

      capture_destroys()
      stub(Managoat.Sandbox, :supports?, fn :sprites, cap -> cap in [:suspend, :checkpoint] end)
      reject(&Managoat.Sandbox.create_checkpoint/2)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      assert Repo.reload(sandbox).status == "suspended"
      refute Repo.reload(sandbox).provider_meta["checkpoint_id"]
    end

    test "a suspended sandbox matches no pass, however old" do
      # The durable resting state: never released, never expired, never
      # destroyed — its sprite is the agent's memory (decisions/0017).
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "suspended")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 24 * 83)

      stub_sprites([sandbox.machine_name])
      capture_destroys()

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)
      end)

      assert Repo.reload(sandbox).status == "suspended"
      assert destroyed_names() == []
    end

    test "a recently touched ready row is inside the grace window" do
      # The wake path flips suspended → ready (touching updated_at) before the
      # new server registers in Horde, whose registry propagates async — so a
      # mid-wake row looks server-less. The grace window keeps the reaper from
      # parking it back out from under the reattach.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})

      # Old activity and an old creation date, but updated_at is fresh.
      ts = minutes_ago(60 * 5)
      Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [inserted_at: ts])

      Repo.update_all(
        from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
        set: [inserted_at: ts]
      )

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    for field <- [:started_at, :ended_at] do
      test "recent turn #{field} keeps an old machine out of the idle sweep" do
        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: sandbox)
        turn = insert_turn(conv, %{status: "completed"})
        sandbox = age_rows(sandbox, conv, 300)
        turn |> change([{unquote(field), minutes_ago(20)}]) |> Repo.update!()

        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          assert {0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
        end)

        assert Repo.reload(sandbox).status == "ready"
      end
    end

    test "a recent wake restarts the idle clock even without a new turn" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      sandbox = age_rows(sandbox, nil, 48 * 60)
      # Outside the 15-minute grace window, but inside the 60-minute idle limit.
      sandbox |> change(last_resumed_at: minutes_ago(20)) |> Repo.update!()
      sandbox = age_sandbox(sandbox, 20)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "recent turn activity keeps a sandbox alive" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      insert_turn(conv, %{status: "completed"})

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "a live ConversationServer is left to enforce its own timeout" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      age_rows(sandbox, conv, 60 * 24 * 83)

      stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
        if id == conv.id, do: self(), else: nil
      end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "with both bounds disabled nothing is expired" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      age_rows(sandbox, conv, 60 * 24 * 83)

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 0], fn ->
        assert {0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "a sandbox that never took a turn is dated from its own creation" do
      # Otherwise a sandbox with no turns has no activity timestamp at all and
      # would either never expire or expire immediately. Five hours old crosses
      # the idle bound but not the ceiling, so the verdict is a park.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      sandbox = age_rows(sandbox, conv, 60 * 5)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      assert Repo.reload(sandbox).status == "suspended"
    end

    test "expiring a sandbox makes its sprite eligible for destruction the same run" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      age_rows(sandbox, conv, 60 * 24 * 83)
      stub_sprites([sandbox.machine_name])
      capture_destroys()

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)
      end)

      assert destroyed_names() == [sandbox.machine_name]
    end
  end

  describe "abandoned teardown fences" do
    # Every row here is fenced through the real `Lifecycle` door, because the
    # thing under test is precisely what that door leaves behind.
    defp fence(sandbox, opts \\ []) do
      {:ok, fenced} =
        Lifecycle.fence_sandbox_for_teardown(sandbox, Keyword.put_new(opts, :reason, "test"))

      fenced
    end

    defp age_fence(sandbox, minutes) do
      at = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second)

      Repo.update_all(
        from(s in Sandbox, where: s.id == ^sandbox.id),
        set: [teardown_requested_at: at]
      )

      Repo.reload(sandbox)
    end

    defp fenced_sandbox(status \\ "ready") do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: status)
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      {user, fence(sandbox), conv}
    end

    test "a teardown that died before its terminal write is finished, freeing the slot" do
      # The hole this pass exists for. The fence commits, then the destroy
      # raises or the pod dies, and the row is left `ready` with the fence set:
      # invisible to both sweeps above (they require is_nil(reset_requested_at),
      # which the fence always sets), to the dead-sprite pass (it wants a
      # terminal status) and to the untracked count (the sprite has a row).
      # Quotas keeps charging for it and nothing else can ever clear it.
      {user, sandbox, _conv} = fenced_sandbox()
      assert Fountain.Quotas.active_sandbox_count(user.id) == 1
      sandbox = age_fence(sandbox, 60)

      capture_log(fn -> assert 1 = SandboxReaper.sweep_fenced_teardowns() end)

      assert %{status: "terminated", terminated_at: %DateTime{}} = Repo.reload(sandbox)
      assert Fountain.Quotas.active_sandbox_count(user.id) == 0
    end

    test "the conversation survives its machine being reclaimed" do
      # Same rule as expire/2: reclaiming a machine is not deleting the thread
      # that ran on it. assert_resumable/1 refuses a terminated conversation.
      {_user, sandbox, conv} = fenced_sandbox()
      age_fence(sandbox, 60)

      capture_log(fn -> assert 1 = SandboxReaper.sweep_fenced_teardowns() end)

      assert Repo.reload(conv).status == "idle"
    end

    test "a teardown still in flight is inside the grace window" do
      # A fence is minutes old on every ordinary teardown, and an account
      # deletion walks a whole tenant's machines between the fence and the
      # destroy. Sweeping those would race a caller that is still working.
      {_user, sandbox, _conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 5)

      assert 0 = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(sandbox).status == "ready"
    end

    test "a fenced row a server still holds is left alone" do
      {_user, sandbox, conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 60)

      stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
        if id == conv.id, do: self(), else: nil
      end)

      assert 0 = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(sandbox).status == "ready"
    end

    test "a reset fence with no teardown intent is not this pass's business" do
      # `reset_requested_at` alone means wipe-and-rebuild, not terminate.
      # SandboxResetReconciler retries those; terminating one here would
      # destroy a home the tenant asked to keep.
      user = insert_verified_user()

      sandbox =
        insert_sandbox(user_id: user.id, status: "ready", mode: "persistent")
        |> Ecto.Changeset.change(
          reset_requested_at: DateTime.utc_now() |> DateTime.add(-60 * 60, :second)
        )
        |> Repo.update!()

      assert 0 = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(sandbox).status == "ready"
    end

    test "an already terminal row needs no work, however long it has been fenced" do
      {_user, sandbox, _conv} = fenced_sandbox()
      age_fence(sandbox, 60)
      sandbox = sandbox |> Ecto.Changeset.change(status: "terminated") |> Repo.update!()

      assert 0 = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(sandbox).status == "terminated"
    end

    test "a suspended row carrying a teardown fence is finished too" do
      # A parked machine is still a leaked sprite once a teardown was
      # requested for it, and Quotas counts a fenced row whatever its status.
      {user, sandbox, _conv} = fenced_sandbox("suspended")
      assert Fountain.Quotas.active_sandbox_count(user.id) == 1
      sandbox = age_fence(sandbox, 60)

      capture_log(fn -> assert 1 = SandboxReaper.sweep_fenced_teardowns() end)

      assert Repo.reload(sandbox).status == "terminated"
      assert Fountain.Quotas.active_sandbox_count(user.id) == 0
    end

    test "the tenant's own trail says what happened to the machine" do
      {user, sandbox, _conv} = fenced_sandbox()
      age_fence(sandbox, 60)

      capture_log(fn -> assert 1 = SandboxReaper.sweep_fenced_teardowns() end)

      assert [event] =
               Fountain.Audit.list_for_user(user.id,
                 action_prefix: "sandbox.teardown_reconciled"
               )

      assert event.actor == "system:sandbox_reaper"
      assert event.resource_id == sandbox.id
      assert event.metadata["previous_status"] == "ready"
      assert event.metadata["sprite_name"] == sandbox.machine_name
    end

    test "finishing a teardown makes its sprite eligible for destruction the same run" do
      # The point of the whole pass: the sprite was leaked, so the run that
      # terminates the row must also be the run that destroys the machine.
      {_user, sandbox, _conv} = fenced_sandbox()
      age_fence(sandbox, 60)
      stub_sprites([sandbox.machine_name])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == [sandbox.machine_name]
      assert Repo.reload(sandbox).status == "terminated"
    end
  end

  describe "leaked sprites" do
    test "destroys a sprite whose sandbox row is terminal" do
      # The ordinary leak: both destroy call sites in ConversationServer discard
      # the result and mark the row terminal regardless, so a transient failure
      # at sprites.dev strands the sprite permanently.
      sandbox = insert_sandbox(status: "terminated")
      stub_sprites([sandbox.machine_name])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == [sandbox.machine_name]
    end

    test "destroys for failed sandboxes as well as terminated" do
      sandbox = insert_sandbox(status: "failed")
      stub_sprites([sandbox.machine_name])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == [sandbox.machine_name]
    end

    test "never destroys a sprite whose sandbox is still live" do
      ready = insert_sandbox(status: "ready")
      pending = insert_sandbox(status: "pending")
      stub_sprites([ready.machine_name, pending.machine_name])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == []
    end

    test "never destroys a sprite with no sandbox row" do
      # The rule that keeps this safe. The same SPRITES_TOKEN can be in a
      # developer's shell or a staging instance, and a sprite created seconds
      # ago may not have committed its row yet — production holds a `jake-*`
      # sprite that is exactly this case. Absence of a row is not evidence of a
      # leak, and this mistake is the one that cannot be undone.
      stub_sprites(["someone-elses-sprite", "aod-conv-legacy"])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == []
    end

    test "untracked sprites are counted so the drift is visible" do
      # Inert is not the same as ignored — an operator still has to be able to
      # see that 102 sprites have no row, which is what production looked like.
      insert_sandbox(status: "ready", machine_name: "known-1")

      test = self()

      :telemetry.attach(
        "reaper-untracked-#{System.unique_integer([:positive])}",
        [:fountain, :reaper, :untracked],
        fn _e, measurements, _meta, _cfg -> send(test, {:untracked, measurements.count}) end,
        nil
      )

      capture_log(fn ->
        assert 2 =
                 SandboxReaper.report_untracked(%{
                   sprites: MapSet.new(["known-1", "stranger-a", "stranger-b"])
                 })
      end)

      assert_received {:untracked, 2}
    end

    test "a row whose sprite is already gone needs no work" do
      insert_sandbox(status: "terminated")
      stub_sprites([])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == []
    end

    test "one destroy failure does not stop the rest" do
      doomed = insert_sandbox(status: "terminated")
      other = insert_sandbox(status: "terminated")
      stub_sprites([doomed.machine_name, other.machine_name])

      test = self()
      stub(Sprites, :sprite, fn :client, name -> {:handle, name} end)

      stub(Sprites, :destroy, fn {:handle, name} ->
        if name == doomed.machine_name do
          {:error, :boom}
        else
          send(test, {:destroyed, name})
          :ok
        end
      end)

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == [other.machine_name]
    end
  end

  describe "when sprites.dev is unreachable" do
    test "stuck rows are still released and the job retries" do
      # The quota fix needs no network, so it must not be held hostage to the
      # API being up. Returning an error lets Oban retry the rest.
      sandbox = insert_sandbox(status: "pending") |> age_sandbox(120)
      stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:error, :nxdomain} end)

      capture_log(fn ->
        # The adapter normalizes unknown transport reasons into the sandbox
        # error taxonomy; any {:error, _} is what lets Oban retry.
        assert {:error, {:provider, :sprites, :nxdomain}} = perform_job(SandboxReaper, %{})
      end)

      assert Repo.reload(sandbox).status == "failed"
    end

    test "a truncated listing destroys nothing" do
      # The client refuses to return a partial page set. Treating a partial
      # view as complete would make every unlisted sprite look like it had
      # already been destroyed.
      sandbox = insert_sandbox(status: "terminated")
      stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:error, :truncated} end)
      capture_destroys()

      capture_log(fn -> assert {:error, :truncated} = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == []
      assert Repo.reload(sandbox).status == "terminated"
    end
  end
end
